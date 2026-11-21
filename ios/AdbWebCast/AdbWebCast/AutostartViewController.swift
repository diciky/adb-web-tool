import UIKit

/// 自启扫描结果缓存：避免每次进入页面都跑一次全量 dumpsys package。
/// 只缓存结构化结果，切换开关后立即失效；下拉刷新可强制重扫。
private enum AutostartStore {
    struct StoredEntry: Codable {
        let pkg: String
        let component: String
        let enabled: Bool
    }
    struct Snapshot: Codable {
        let savedAt: TimeInterval
        let entries: [StoredEntry]
        /// 本地禁用的组件列表（旧版 pm disable 方案遗留，仅向后兼容读取）。
        let disabled: [String]?
        /// v3.9.2：整包后台自启被 appops 禁止的包名集合。
        /// Android 8+ shell 无权 pm disable 组件（真机实测 SecurityException），
        /// 改用 `cmd appops set <pkg> RUN_ANY_IN_BACKGROUND deny` 整包级禁止。
        let denied: [String]?
    }

    static let ttl: TimeInterval = 30 * 60
    private static let queue = DispatchQueue(label: "adbweb.autostart.cache")

    private static func fileURL(host: AdbHost) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("AdbWebCast/autostart", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let key = "\(host.ip)-\(host.port)".replacingOccurrences(of: ".", with: "_")
        return dir.appendingPathComponent("\(key).json")
    }

    static func load(host: AdbHost) -> (entries: [AutostartEntry], disabled: Set<String>, denied: Set<String>)? {
        queue.sync {
            guard let url = fileURL(host: host),
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  Date().timeIntervalSince1970 - snapshot.savedAt < ttl else { return nil }
            return (snapshot.entries.map { AutostartEntry(pkg: $0.pkg, component: $0.component, enabled: $0.enabled) },
                    Set(snapshot.disabled ?? []),
                    Set(snapshot.denied ?? []))
        }
    }

    static func save(host: AdbHost, entries: [AutostartEntry], disabled: Set<String>, denied: Set<String>) {
        queue.sync {
            guard let url = fileURL(host: host) else { return }
            let stored = entries.map { StoredEntry(pkg: $0.pkg, component: $0.component, enabled: $0.enabled) }
            let snapshot = Snapshot(savedAt: Date().timeIntervalSince1970, entries: stored,
                                    disabled: Array(disabled), denied: Array(denied))
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// v3.9.2：记录整包自启禁止/恢复（切换成功后调用），无需重扫 dumpsys。
    static func setDenied(host: AdbHost, pkg: String, denied: Bool) {
        queue.sync {
            guard let url = fileURL(host: host),
                  let data = try? Data(contentsOf: url),
                  var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
            var set = Set(snapshot.denied ?? [])
            if denied { set.insert(pkg) } else { set.remove(pkg) }
            guard let out = try? JSONEncoder().encode(
                Snapshot(savedAt: snapshot.savedAt, entries: snapshot.entries,
                         disabled: snapshot.disabled, denied: Array(set)))
            else { return }
            try? out.write(to: url, options: .atomic)
        }
    }

    /// 记录本地禁用/启用覆盖（切换成功后调用）。
    static func setDisabled(host: AdbHost, component: String, disabled: Bool) {
        queue.sync {
            guard let url = fileURL(host: host),
                  let data = try? Data(contentsOf: url),
                  var snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
            var set = Set(snapshot.disabled ?? [])
            if disabled { set.insert(component) } else { set.remove(component) }
            guard let out = try? JSONEncoder().encode(
                Snapshot(savedAt: snapshot.savedAt, entries: snapshot.entries, disabled: Array(set)))
            else { return }
            try? out.write(to: url, options: .atomic)
        }
    }

    static func invalidate(host: AdbHost) {
        queue.sync {
            guard let url = fileURL(host: host) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// 自启条目按应用分组后的展示模型：
/// 同一包名的多个 BOOT_COMPLETED 组件（如 Twitch 的 BootReceiver + WorkManager Receiver）
/// 归到同一行，列表页每行显示应用图标 + 中文名。
fileprivate struct AutostartAppGroup {
    let pkg: String
    let entries: [AutostartEntry]
    /// 该应用后台自启是否被 appops 禁止（整包级，Android 8+ 唯一可靠的 shell 禁自启手段）
    var bgDenied: Bool = false
}

/// 自启管理页：列出具备 BOOT_COMPLETED 接收器的应用，启用/禁用其开机自启组件。
///
/// 实现要点：
/// - 一次 `dumpsys package` 全量读取，按 `Package [xxx]` 分段解析，避免对 300 个包逐个 dumpsys。
/// - 包名直接取自分段标题，绝不再从 `pm list packages -f` 的路径里切（路径 hash 以 `==`
///   结尾会把 `firstIndex(of: "=")` 骗到，得到 `=/base.apk=<pkg>` 这种坏包名）。
/// - 同时识别 BOOT_COMPLETED 接收器组件与 RECEIVE_BOOT_COMPLETED 权限，兼容国产固件。
final class AutostartViewController: UIViewController {

    private let host: AdbHost
    /// 按应用分组后的展示模型：同一应用的多个 BOOT_COMPLETED 组件归成一行，
    /// 避免同一应用（如 Twitch/SmartTube）因注册了多个 Receiver 重复出现。
    private var groups: [AutostartAppGroup] = []
    /// 包名 -> 显示名（中文优先），用于把 component 前面的包名替换成人看得懂的名字
    private var labels: [String: String] = [:]
    /// 包名 -> 应用图标（来自 AppLabelResolver 持久化缓存）
    private var icons: [String: UIImage] = [:]

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .footnote)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.adjustsFontForContentSizeCategory = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自启管理"
        view.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = refresh
        refresh.addTarget(self, action: #selector(pullRefreshed), for: .valueChanged)
        let header = UIView()
        header.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
        ])
        header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 56)
        header.layoutIfNeeded()
        tableView.tableHeaderView = header
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        statusLabel.accessibilityLabel = "自启项加载状态"
        load()
    }

    @objc private func pullRefreshed() { load(force: true) }

    private func load(force: Bool = false) {
        // 先显示本地缓存，避免每次进页面都等一次全量 dumpsys。
        if !force, let cached = AutostartStore.load(host: host) {
            apply(entries: Self.mergingDisabled(cached.entries, disabled: cached.disabled),
                  deniedPkgs: cached.denied, fromCache: true, error: "", force: false)
            return
        }

        statusLabel.text = "正在读取开机自启项（全量扫描，约数秒）…"
        refresh.beginRefreshing()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var parsed: [AutostartEntry] = []
            var deniedPkgs = Set<String>()
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                // 用户应用包集合（/data 路径），与 Web 端一致：只显示第三方应用的自启项，
                // 否则 60+ 个系统 Receiver 会把列表淹没。
                var userPackages = Set<String>()
                let pkgOut = (try? client.shell("pm list packages -f", timeout: 90)) ?? ""
                for line in pkgOut.split(separator: "\n") {
                    let s = line.trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix("package:/data"), let eq = s.lastIndex(of: "=") else { continue }
                    let pkg = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !pkg.isEmpty { userPackages.insert(pkg) }
                }
                // 一次读取全部包信息，避免逐个 dumpsys（慢且易失败）
                let dump = try client.shell("dumpsys package", timeout: 120)
                let all = Self.parseAutostart(from: dump)
                // 有用户包集合时只保留第三方；拿不到集合（固件不支持 -f）时降级显示全部
                parsed = userPackages.isEmpty ? all : all.filter { userPackages.contains($0.pkg) }
                // v3.9.2：批量读取每个用户包的后台自启禁止状态（appops 整包级，
                // 一条 shell 搞定，避免逐包连接）。deny 输出含 "RUN_ANY_IN_BACKGROUND: deny"
                // 或 "Default mode: deny"；未设置时是 "Default mode: allow"。
                var deniedLocal = Set<String>()
                let targets = userPackages.isEmpty ? Set(parsed.map { $0.pkg }) : userPackages
                if !targets.isEmpty {
                    let script = "for p in \(targets.sorted().joined(separator: " ")); do "
                        + "echo \"PKGBEGIN:$p\"; cmd appops get $p RUN_ANY_IN_BACKGROUND; done"
                    let opsOut = (try? client.shell(script, timeout: 60)) ?? ""
                    deniedLocal = Self.parseDeniedPkgs(from: opsOut)
                }
                deniedPkgs = deniedLocal
                let disabledSet = AutostartStore.load(host: self.host)?.disabled ?? []
                AutostartStore.save(host: self.host, entries: parsed, disabled: disabledSet, denied: deniedPkgs)
                client.disconnect()
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                self.apply(entries: Self.mergingDisabled(parsed, disabled: AutostartStore.load(host: self.host)?.disabled ?? []),
                           deniedPkgs: deniedPkgs, fromCache: false, error: err, force: force)
            }
        }
    }

    /// 解析批量 `cmd appops get <pkg> RUN_ANY_IN_BACKGROUND` 输出（真机实测格式：
    /// "PKGBEGIN:pkg\nNo operations.\nDefault mode: allow" 或 "PKGBEGIN:pkg\nRUN_ANY_IN_BACKGROUND: deny"）
    static func parseDeniedPkgs(from text: String) -> Set<String> {
        var denied = Set<String>()
        var currentPkg = ""
        for line in text.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("PKGBEGIN:") {
                currentPkg = String(s.dropFirst("PKGBEGIN:".count))
                continue
            }
            guard !currentPkg.isEmpty else { continue }
            if s.contains("deny") { denied.insert(currentPkg) }
        }
        return denied
    }

    /// 统一渲染：先灌入持久化资源缓存，再对未解析包做小批量补全。
    private func apply(entries: [AutostartEntry], deniedPkgs: Set<String>?, fromCache: Bool, error: String, force: Bool) {
        // 按包名分组（保持首次出现顺序），一行一个应用
        var order: [String] = []
        var byPkg: [String: [AutostartEntry]] = [:]
        for e in entries {
            if byPkg[e.pkg] == nil { order.append(e.pkg) }
            byPkg[e.pkg, default: []].append(e)
        }
        let deniedSet = deniedPkgs ?? (AutostartStore.load(host: host)?.denied ?? [])
        groups = order.map { pkg in
            var g = AutostartAppGroup(pkg: pkg, entries: byPkg[pkg] ?? [])
            g.bgDenied = deniedSet.contains(pkg)
            return g
        }

        var resolvedLabels: [String: String] = [:]
        var resolvedIcons: [String: UIImage] = [:]
        for g in groups {
            guard let cached = AppLabelResolver.cached(pkg: g.pkg) else { continue }
            if let label = cached.label, !label.isEmpty { resolvedLabels[g.pkg] = label }
            if let data = cached.iconData, let image = UIImage(data: data) { resolvedIcons[g.pkg] = image }
        }
        self.labels = resolvedLabels
        self.icons = resolvedIcons

        if error.isEmpty {
            if groups.isEmpty {
                statusLabel.text = "未发现开机自启项（该电视可能未开放第三方自启，或已全部禁用）"
            } else {
                let suffix = fromCache ? " · 本地缓存（下拉强制重扫）" : " · 点按应用管理自启组件"
                statusLabel.text = "发现 \(groups.count) 个自启应用（共 \(entries.count) 个组件）\(suffix)"
            }
        } else {
            statusLabel.text = "读取失败：\(error)（下拉重试）"
        }
        tableView.reloadData()
        refresh.endRefreshing()
        resolveAssetsIfNeeded(for: groups.map { $0.pkg }, force: force)
    }

    /// dumpsys 的 Resolver Table 不包含已禁用组件；把本地记录的禁用项合并回列表，
    /// 这样用户能在 App 里看到「已禁用」并重新启用。
    private static func mergingDisabled(_ entries: [AutostartEntry], disabled: Set<String>) -> [AutostartEntry] {
        guard !disabled.isEmpty else { return entries }
        var comps = Set(entries.map { $0.component })
        var result = entries
        for comp in disabled where !comps.contains(comp) {
            let pkg = String(comp.split(separator: "/", maxSplits: 1).first ?? Substring(comp))
            result.append(AutostartEntry(pkg: pkg, component: comp, enabled: false))
            comps.insert(comp)
        }
        return result
    }

    /// 自启页只解析自己列表里的包（通常十几个），不会扫描设备上所有应用。
    /// force=true（下拉强制重扫）时先清掉失败缓存，让名称/图标缺失的包立即重试。
    private func resolveAssetsIfNeeded(for pkgs: [String], force: Bool) {
        let unique = Array(Set(pkgs))
        if force { AppLabelResolver.clearIncompleteRecords(pkgs: unique) }
        let pending = unique.filter { !AppLabelResolver.isResolved(pkg: $0) }
        guard !pending.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for pkg in pending {
                // 每个包独立连接：一次 pull 超时/失败可能污染共享传输的帧流，
                // 导致后续所有包连锁失败；断开重连保证每个包拿到干净通道。
                let client = AdbClient()
                do {
                    try client.connect(host: self.host.ip, port: self.host.port)
                } catch {
                    AdbLog.log("自启项资源解析连接失败：\(error.localizedDescription)", level: "W")
                    client.disconnect()
                    return
                }
                let assets = AppLabelResolver.assets(for: pkg, apkPath: "", client: client)
                client.disconnect()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let label = assets.label, !label.isEmpty { self.labels[pkg] = label }
                    if let data = assets.iconData, let image = UIImage(data: data) { self.icons[pkg] = image }
                    self.tableView.reloadData()
                }
            }
        }
    }

    /// 解析全量 `dumpsys package` 输出，返回所有 BOOT_COMPLETED 自启组件。
    ///
    /// 关键：全量 dump 与单包 dump 结构完全不同：
    /// - 全量（本 App 采用）：顶层是「Receiver Resolver Table」，按 action 聚合，
    ///   `android.intent.action.BOOT_COMPLETED:` 下的每一行就是一个自启组件：
    ///       android.intent.action.BOOT_COMPLETED:
   ///         33148b ar.tvplayer.tv/.base.BootReceiver
   ///         9835fb com.sony.dtv.b2b.rs232csupport/.BootCompletedReceiver
    ///   这种输出里**没有** `Package [xxx]` 分段，旧版按段取包名会恒为空。
    /// - 单包（部分固件 fallback）：`Package [xxx]` 分段 + 段内 Receiver Resolver。
    ///
    /// 实测 BRAVIA Android 9 全量输出含 81 个 BOOT_COMPLETED 组件，Web 端同款数据。
    static func parseAutostart(from dump: String) -> [AutostartEntry] {
        let lines = dump.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [AutostartEntry] = []
        var seen = Set<String>()

        // 组件行：缩进 + 6~8 位十六进制 hash + 空白 + 包名/类名
        let componentPattern = #"^\s+[0-9a-fA-F]{6,}\s+([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+)/([a-zA-Z0-9_.$]+)"#
        let componentRegex = try? NSRegularExpression(pattern: componentPattern)

        // ---- 主路径：全量 Resolver Table 格式 ----
        // 只在「精确等于 android.intent.action.BOOT_COMPLETED:」时进入，
        // 排除 BOOT_COMPLETED.PROXY / PRE_ / LOCKED_ / ACTION_ 等变体 action。
        let bootAction = "android.intent.action.BOOT_COMPLETED:"
        var inBootSection = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == bootAction {
                inBootSection = true
                continue
            }
            guard inBootSection else { continue }
            // 遇到其它 action（以非空白开头）或空行，结束本节
            if trimmed.isEmpty || (!line.hasPrefix(" ") && !line.hasPrefix("\t")) {
                if !trimmed.isEmpty { inBootSection = false }
                continue
            }
            guard let regex = componentRegex,
                  let m = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let pkgRange = Range(m.range(at: 1), in: line),
                  let clsRange = Range(m.range(at: 2), in: line) else {
                // 遇到非组件行即本节结束（下一个 action 标题，或 filter 明细）
                inBootSection = false
                continue
            }
            let pkg = String(line[pkgRange])
            let comp = "\(pkg)/\(String(line[clsRange]))"
            guard !seen.contains(comp) else { continue }
            seen.insert(comp)
            result.append(AutostartEntry(pkg: pkg, component: comp, enabled: true))
        }

        // ---- fallback：单包 / 带 Package [xxx] 分段的固件 ----
        if result.isEmpty {
            var segments: [(pkg: String, lines: [String])] = []
            var currentPkg = ""
            var currentLines: [String] = []
            for line in lines {
                if let pkg = packageName(from: line) {
                    if !currentPkg.isEmpty { segments.append((currentPkg, currentLines)) }
                    currentPkg = pkg
                    currentLines = []
                } else if !currentPkg.isEmpty {
                    currentLines.append(line)
                }
            }
            if !currentPkg.isEmpty { segments.append((currentPkg, currentLines)) }

            let loosePattern = #"([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+)/([a-zA-Z0-9_.$]+)"#
            let looseRegex = try? NSRegularExpression(pattern: loosePattern)
            for seg in segments {
                let pkg = seg.pkg
                let body = seg.lines
                var hasBootPerm = false
                var components: [(String, Bool)] = []
                for (i, line) in body.enumerated() {
                    if line.contains("RECEIVE_BOOT_COMPLETED") {
                        hasBootPerm = !line.contains("granted=false")
                    }
                    guard line.contains("android.intent.action.BOOT_COMPLETED") else { continue }
                    let lo = max(0, i - 4)
                    let hi = min(body.count - 1, i + 4)
                    let window = body[lo...hi].joined(separator: "\n")
                    guard let regex = looseRegex,
                          let m = regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
                          let r = Range(m.range, in: window) else { continue }
                    let matched = String(window[r])
                    let parts = matched.split(separator: "/", maxSplits: 1)
                    var comp: String
                    if parts.count == 2 {
                        let owner = String(parts[0])
                        let cls = String(parts[1])
                        comp = owner == pkg ? matched : "\(pkg)/\(cls)"
                    } else {
                        comp = matched
                    }
                    let enabled = !window.contains("enabled=false")
                    if !seen.contains(comp) {
                        seen.insert(comp)
                        components.append((comp, enabled))
                    }
                }
                if components.isEmpty {
                    if hasBootPerm {
                        let comp = "\(pkg)/*"
                        if !seen.contains(comp) {
                            seen.insert(comp)
                            result.append(AutostartEntry(pkg: pkg, component: comp, enabled: true))
                        }
                    }
                } else {
                    for (comp, enabled) in components {
                        result.append(AutostartEntry(pkg: pkg, component: comp, enabled: enabled))
                    }
                }
            }
        }
        return result
    }

    /// 从 dumpsys 的 `Package [com.foo] (...)` 行提取包名（fallback 用）
    private static func packageName(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Package [") else { return nil }
        guard let close = trimmed.firstIndex(of: "]") else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: 9)
        let pkg = String(trimmed[start..<close]).trimmingCharacters(in: .whitespaces)
        // 合法 Android 包名至少含一个点
        return pkg.contains(".") ? pkg : nil
    }

    /// v3.9.2：切换整包后台自启（appops）。
    /// Android 8+ shell 无权 pm disable 组件（真机实测 SecurityException），
    /// 整包级 `cmd appops set <pkg> RUN_ANY_IN_BACKGROUND deny` 是唯一可靠的 shell 禁自启手段。
    /// 注意：shell 命令失败时只输出错误文本不抛异常，必须检查输出内容，
    /// 否则会像旧版 pm disable 一样误判成功。
    private func toggleAutostart(pkg: String, deny: Bool, completion: ((String?) -> Void)? = nil) {
        let cmd = "cmd appops set \(pkg) RUN_ANY_IN_BACKGROUND \(deny ? "deny" : "allow")"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                let out = try client.shell(cmd, timeout: 30)
                client.disconnect()
                let lowered = out.lowercased()
                if lowered.contains("exception") || lowered.contains("security") || lowered.contains("error") {
                    err = "设备拒绝了该操作：\(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))"
                }
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                if err.isEmpty {
                    AutostartStore.setDenied(host: self.host, pkg: pkg, denied: deny)
                    // appops 不影响 dumpsys Resolver Table，无需重扫，直接更新本地状态
                    self.groups = self.groups.map { g in
                        guard g.pkg == pkg else { return g }
                        var copy = g
                        copy.bgDenied = deny
                        return copy
                    }
                    self.tableView.reloadData()
                    completion?(nil)
                } else {
                    UIKitHelper.alert("禁用失败", err, in: self)
                    completion?(err)
                }
            }
        }
    }

    /// 停止应用运行（force-stop）：禁自启后立即杀掉已运行的进程，让限制马上生效。
    private func forceStopApp(pkg: String, completion: ((String?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let client = AdbClient()
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                _ = try client.shell("am force-stop \(pkg)", timeout: 30)
                client.disconnect()
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                if err.isEmpty {
                    UIKitHelper.alert("完成", "已停止 \(pkg) 的所有进程", in: self)
                    completion?(nil)
                } else {
                    UIKitHelper.alert("失败", err, in: self)
                    completion?(err)
                }
            }
        }
    }

    /// 组件短名："pkg/.base.BootReceiver" → "BootReceiver"，
    /// "pkg/androidx.work...RescheduleReceiver" → "RescheduleReceiver"
    fileprivate static func shortComponentName(_ component: String) -> String {
        guard let slash = component.firstIndex(of: "/") else { return component }
        let cls = String(component[component.index(after: slash)...])
        let parts = cls.split(separator: ".")
        return parts.last.map(String.init) ?? cls
    }
}

extension AutostartViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { groups.count }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let g = groups[indexPath.row]
        let name = labels[g.pkg] ?? g.pkg
        var cfg = cell.defaultContentConfiguration()
        cfg.text = name
        // 状态：整包后台自启是否被 appops 禁止（v3.9.2：Android 8+ 唯一可靠手段，整包级）
        let status: String
        let statusColor: UIColor
        if g.bgDenied {
            status = "自启已禁止"; statusColor = .systemOrange
        } else {
            status = "允许自启"; statusColor = .systemGreen
        }
        // 组件短名（最多展示 2 个）
        let comps = g.entries.map { Self.shortComponentName($0.component) }
        let shown = comps.prefix(2).joined(separator: "、")
        let more = comps.count > 2 ? " 等\(comps.count)个" : ""
        cfg.secondaryText = "\(g.entries.count) 个自启组件 · \(status) · \(shown)\(more)"
        cfg.secondaryTextProperties.color = statusColor
        let appImage: UIImage? = icons[g.pkg] ?? (AppLabelResolver.cachedIcon(pkg: g.pkg).flatMap { UIImage(data: $0) })
        if let appImage = appImage {
            cfg.image = appImage.withRenderingMode(.alwaysOriginal)
            cfg.imageProperties.cornerRadius = 6
        } else {
            cfg.image = UIImage(systemName: g.bgDenied ? "bolt.slash" : "bolt.fill")
            cfg.imageProperties.tintColor = g.bgDenied ? .secondaryLabel : .systemOrange
        }
        cfg.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = "\(name)，\(g.entries.count) 个自启组件，\(status)"
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let g = groups[indexPath.row]
        let name = labels[g.pkg] ?? g.pkg
        let icon = icons[g.pkg] ?? (AppLabelResolver.cachedIcon(pkg: g.pkg).flatMap { UIImage(data: $0) })
        let detail = AutostartComponentListViewController(group: g, appName: name, appIcon: icon,
                                                          toggleHandler: { [weak self] pkg, deny, done in
            self?.toggleAutostart(pkg: pkg, deny: deny, completion: done)
        }, stopHandler: { [weak self] pkg, done in
            self?.forceStopApp(pkg: pkg, completion: done)
        })
        navigationController?.pushViewController(detail, animated: true)
    }
}

// MARK: - 单应用自启管理页（v3.9.2）

/// 单个应用的自启管理：顶部整包开关（appops 后台自启禁止）+ 停止应用 +
/// 只读组件清单。Android 8+ shell 无权 pm disable 单个组件，组件仅作展示。
private final class AutostartComponentListViewController: UIViewController {
    private var group: AutostartAppGroup
    private let appName: String
    private let appIcon: UIImage?
    /// 整包切换回调：(pkg, deny, completion(err))，成功后 err 为 nil。
    private let toggleHandler: (String, Bool, @escaping (String?) -> Void) -> Void
    /// 停止应用回调：(pkg, completion(err))
    private let stopHandler: (String, @escaping (String?) -> Void) -> Void
    private var toggling = false

    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 15, weight: .medium)
        l.adjustsFontForContentSizeCategory = true; return l
    }()
    private let statusDetail: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel; l.numberOfLines = 0
        l.adjustsFontForContentSizeCategory = true
        l.text = "Android 8+ 系统限制：只能整包禁止应用在后台自启（组件级开关已不再可用）。禁止后应用仍可手动打开使用。"
        return l
    }()
    private let toggleButton: UIButton = {
        let b = UIButton(type: .system)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        return b
    }()
    private let stopButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("停止应用运行", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.accessibilityLabel = "强制停止该应用的所有进程"
        return b
    }()

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()

    init(group: AutostartAppGroup, appName: String, appIcon: UIImage?,
         toggleHandler: @escaping (String, Bool, @escaping (String?) -> Void) -> Void,
         stopHandler: @escaping (String, @escaping (String?) -> Void) -> Void) {
        self.group = group
        self.appName = appName
        self.appIcon = appIcon
        self.toggleHandler = toggleHandler
        self.stopHandler = stopHandler
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = appName
        view.backgroundColor = .systemBackground

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 12
        let cardStack = UIStackView(arrangedSubviews: [statusLabel, statusDetail, toggleButton, stopButton])
        cardStack.axis = .vertical; cardStack.spacing = 10
        cardStack.layoutMargins = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        cardStack.isLayoutMarginsRelativeArrangement = true
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        let headerLabel = UILabel()
        headerLabel.text = "自启组件（来自系统扫描，供参考）"
        headerLabel.font = .systemFont(ofSize: 13)
        headerLabel.textColor = .secondaryLabel

        view.addSubview(card)
        view.addSubview(headerLabel)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            headerLabel.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 16),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        tableView.dataSource = self
        refreshStatusUI()
    }

    private func refreshStatusUI() {
        if group.bgDenied {
            statusLabel.text = "自启已禁止"
            statusLabel.textColor = .systemOrange
            toggleButton.setTitle("恢复允许自启", for: .normal)
        } else {
            statusLabel.text = "当前允许后台自启（开机 / 网络变化等时机自动拉起）"
            statusLabel.textColor = .label
            toggleButton.setTitle("禁止后台自启", for: .normal)
        }
        toggleButton.accessibilityLabel = group.bgDenied ? "恢复允许自启" : "禁止后台自启"
    }

    @objc private func toggleTapped() {
        guard !toggling else { return }
        let deny = !group.bgDenied
        let action = deny ? "禁止后台自启" : "恢复允许自启"
        UIKitHelper.confirm(action, "\(appName)\n\n整包级操作：\(deny ? "禁止该应用在后台被系统自动拉起" : "恢复该应用的后台自启能力")",
                            in: self, destructive: deny) { [weak self] in
            guard let self else { return }
            self.toggling = true
            self.toggleHandler(self.group.pkg, deny) { [weak self] err in
                guard let self else { return }
                self.toggling = false
                guard err == nil else { return }
                self.group.bgDenied = deny
                self.refreshStatusUI()
            }
        }
    }

    @objc private func stopTapped() {
        UIKitHelper.confirm("停止应用", "结束 \(appName) 的所有进程，未保存的数据会丢失。", in: self) { [weak self] in
            guard let self else { return }
            self.stopHandler(self.group.pkg) { _ in }
        }
    }
}

extension AutostartComponentListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { group.entries.count }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let e = group.entries[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = AutostartViewController.shortComponentName(e.component)
        cfg.secondaryText = e.component
        cfg.secondaryTextProperties.color = .secondaryLabel
        if let appIcon {
            cfg.image = appIcon.withRenderingMode(.alwaysOriginal)
            cfg.imageProperties.cornerRadius = 6
        } else {
            cfg.image = UIImage(systemName: "bolt.fill")
            cfg.imageProperties.tintColor = .systemOrange
        }
        cfg.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        cell.contentConfiguration = cfg
        cell.selectionStyle = .none
        cell.accessibilityLabel = "自启组件 \(e.component)"
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        // 组件级开关在 Android 8+ 已不可用（shell 权限限制），整包开关在上方卡片
    }
}

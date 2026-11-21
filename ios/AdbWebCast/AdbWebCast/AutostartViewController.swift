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
        /// 本地禁用的组件列表。dumpsys 的 Resolver Table 不含已禁用组件，
        /// 必须本地记忆才能在列表里以「已禁用」状态展示并允许重新启用。
        let disabled: [String]?
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

    static func load(host: AdbHost) -> (entries: [AutostartEntry], disabled: Set<String>)? {
        queue.sync {
            guard let url = fileURL(host: host),
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  Date().timeIntervalSince1970 - snapshot.savedAt < ttl else { return nil }
            return (snapshot.entries.map { AutostartEntry(pkg: $0.pkg, component: $0.component, enabled: $0.enabled) },
                    Set(snapshot.disabled ?? []))
        }
    }

    static func save(host: AdbHost, entries: [AutostartEntry], disabled: Set<String>) {
        queue.sync {
            guard let url = fileURL(host: host) else { return }
            let stored = entries.map { StoredEntry(pkg: $0.pkg, component: $0.component, enabled: $0.enabled) }
            let snapshot = Snapshot(savedAt: Date().timeIntervalSince1970, entries: stored,
                                    disabled: Array(disabled))
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
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
                  fromCache: true, error: "", force: false)
            return
        }

        statusLabel.text = "正在读取开机自启项（全量扫描，约数秒）…"
        refresh.beginRefreshing()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var parsed: [AutostartEntry] = []
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
                let disabledSet = AutostartStore.load(host: self.host)?.disabled ?? []
                AutostartStore.save(host: self.host, entries: parsed, disabled: disabledSet)
                client.disconnect()
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                self.apply(entries: Self.mergingDisabled(parsed, disabled: AutostartStore.load(host: self.host)?.disabled ?? []),
                           fromCache: false, error: err, force: force)
            }
        }
    }

    /// 统一渲染：先灌入持久化资源缓存，再对未解析包做小批量补全。
    private func apply(entries: [AutostartEntry], fromCache: Bool, error: String, force: Bool) {
        // 按包名分组（保持首次出现顺序），一行一个应用
        var order: [String] = []
        var byPkg: [String: [AutostartEntry]] = [:]
        for e in entries {
            if byPkg[e.pkg] == nil { order.append(e.pkg) }
            byPkg[e.pkg, default: []].append(e)
        }
        groups = order.map { AutostartAppGroup(pkg: $0, entries: byPkg[$0] ?? []) }

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

    private func toggle(_ entry: AutostartEntry, completion: ((String?) -> Void)? = nil) {
        // 粗粒度组件（pkg/*）用包级开关；精确组件用组件级开关
        let comp = entry.component
        let cmd: String
        if comp.hasSuffix("/*") {
            let pkg = String(comp.dropLast(2))
            cmd = entry.enabled ? "pm disable \(pkg)" : "pm enable \(pkg)"
        } else {
            cmd = entry.enabled ? "pm disable \(comp)" : "pm enable \(comp)"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                _ = try client.shell(cmd, timeout: 30)
                client.disconnect()
                // 本地记忆禁用/启用：禁用的组件会从 dumpsys Resolver Table 消失，
                // 必须记忆才能在列表里以「已禁用」展示并允许重新启用。
                AutostartStore.setDisabled(host: self.host, component: comp, disabled: entry.enabled)
                AutostartStore.invalidate(host: self.host)
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                if err.isEmpty {
                    self.load()
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
        // 状态：全启用/全禁用/部分启用
        let enabledCount = g.entries.filter { $0.enabled }.count
        let status: String
        let statusColor: UIColor
        if enabledCount == g.entries.count {
            status = "已启用"; statusColor = .systemGreen
        } else if enabledCount == 0 {
            status = "已禁用"; statusColor = .secondaryLabel
        } else {
            status = "\(enabledCount)/\(g.entries.count) 启用"; statusColor = .secondaryLabel
        }
        // 组件短名（最多展示 2 个）
        let comps = g.entries.map { Self.shortComponentName($0.component) }
        let shown = comps.prefix(2).joined(separator: "、")
        let more = comps.count > 2 ? " 等\(comps.count)个组件" : ""
        cfg.secondaryText = "\(shown)\(more) · \(status)"
        cfg.secondaryTextProperties.color = statusColor
        let appImage: UIImage? = icons[g.pkg] ?? (AppLabelResolver.cachedIcon(pkg: g.pkg).flatMap { UIImage(data: $0) })
        if let appImage = appImage {
            cfg.image = appImage.withRenderingMode(.alwaysOriginal)
            cfg.imageProperties.cornerRadius = 6
        } else {
            cfg.image = UIImage(systemName: enabledCount > 0 ? "bolt.fill" : "bolt.slash")
            cfg.imageProperties.tintColor = enabledCount > 0 ? .systemOrange : .secondaryLabel
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
        let detail = AutostartComponentListViewController(group: g, appName: name, appIcon: icon) { [weak self] entry, done in
            self?.toggle(entry, completion: done)
        }
        navigationController?.pushViewController(detail, animated: true)
    }
}

// MARK: - 单应用自启组件管理页

/// 单个应用的自启组件列表：每个 BOOT_COMPLETED 接收器一行，点按切换启用/禁用。
private final class AutostartComponentListViewController: UIViewController {
    private let group: AutostartAppGroup
    private let appName: String
    private let appIcon: UIImage?
    /// 切换回调：(entry, completion(err))，成功后 err 为 nil。
    private let toggleHandler: (AutostartEntry, @escaping (String?) -> Void) -> Void

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()

    init(group: AutostartAppGroup, appName: String, appIcon: UIImage?,
         toggleHandler: @escaping (AutostartEntry, @escaping (String?) -> Void) -> Void) {
        self.group = group
        self.appName = appName
        self.appIcon = appIcon
        self.toggleHandler = toggleHandler
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = appName
        view.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

extension AutostartComponentListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { group.entries.count }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let e = group.entries[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = AutostartViewController.shortComponentName(e.component)
        cfg.secondaryText = e.component + (e.enabled ? " · 已启用" : " · 已禁用")
        cfg.secondaryTextProperties.color = e.enabled ? .systemGreen : .secondaryLabel
        if let appIcon {
            cfg.image = appIcon.withRenderingMode(.alwaysOriginal)
            cfg.imageProperties.cornerRadius = 6
        } else {
            cfg.image = UIImage(systemName: e.enabled ? "bolt.fill" : "bolt.slash")
            cfg.imageProperties.tintColor = e.enabled ? .systemOrange : .secondaryLabel
        }
        cfg.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        cell.contentConfiguration = cfg
        cell.accessibilityLabel = "\(e.component)，\(e.enabled ? "已启用" : "已禁用")，点按切换"
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let e = group.entries[indexPath.row]
        UIKitHelper.confirm(e.enabled ? "禁用自启" : "启用自启",
                            "\(appName)\n\(e.component)", in: self, destructive: e.enabled) { [weak self] in
            guard let self else { return }
            self.toggleHandler(e) { [weak self] err in
                guard let self, err == nil else { return }
                // 切换成功：禁用的组件会从扫描结果消失/启用的会重新出现，返回上级页看最新状态
                self.navigationController?.popViewController(animated: true)
            }
        }
    }
}

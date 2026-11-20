import UIKit

/// 自启管理页：列出具备 BOOT_COMPLETED 接收器的应用，启用/禁用其开机自启组件。
///
/// 实现要点：
/// - 一次 `dumpsys package` 全量读取，按 `Package [xxx]` 分段解析，避免对 300 个包逐个 dumpsys。
/// - 包名直接取自分段标题，绝不再从 `pm list packages -f` 的路径里切（路径 hash 以 `==`
///   结尾会把 `firstIndex(of: "=")` 骗到，得到 `=/base.apk=<pkg>` 这种坏包名）。
/// - 同时识别 BOOT_COMPLETED 接收器组件与 RECEIVE_BOOT_COMPLETED 权限，兼容国产固件。
final class AutostartViewController: UIViewController {

    private let host: AdbHost
    private var entries: [AutostartEntry] = []
    /// 包名 -> 显示名（中文优先），用于把 component 前面的包名替换成人看得懂的名字
    private var labels: [String: String] = [:]

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
        refresh.addTarget(self, action: #selector(load), for: .valueChanged)
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

    @objc private func load() {
        statusLabel.text = "正在读取开机自启项（全量扫描，约数秒）…"
        refresh.beginRefreshing()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var parsed: [AutostartEntry] = []
            var pkgLabels: [String: String] = [:]
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                // 一次读取全部包信息，避免逐个 dumpsys（慢且易失败）
                let dump = try client.shell("dumpsys package", timeout: 120)
                parsed = Self.parseAutostart(from: dump)

                // 用已知的应用名缓存补齐中文显示名（不额外打 APK）
                var pkgs = Set<String>()
                for e in parsed {
                    let p = String(e.component.split(separator: "/").first ?? Substring(e.pkg))
                    pkgs.insert(p)
                }
                for p in pkgs {
                    if let label = AppLabelResolver.cachedLabel(pkg: p, apkPath: "") {
                        pkgLabels[p] = label
                    }
                }
                client.disconnect()
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                self.entries = parsed
                self.labels = pkgLabels
                self.statusLabel.text = err.isEmpty
                    ? (parsed.isEmpty
                        ? "未发现开机自启项（该电视可能未开放第三方自启，或已全部禁用）"
                        : "发现 \(parsed.count) 个自启项 · 点按切换启用/禁用")
                    : "读取失败：\(err)（下拉重试）"
                self.tableView.reloadData()
                self.refresh.endRefreshing()
            }
        }
    }

    /// 解析全量 `dumpsys package` 输出，返回所有 BOOT_COMPLETED 自启组件。
    ///
    /// dumpsys 结构（各厂商大致相同）：
    ///   Package [com.foo] (...)
    ///     ...
    ///     Receiver Resolver Table:
    ///       Non-Data Actions:
    ///         android.intent.action.BOOT_COMPLETED:
    ///           com.foo/.BootReceiver filter ...
    ///     ...
    static func parseAutostart(from dump: String) -> [AutostartEntry] {
        let lines = dump.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [AutostartEntry] = []
        var seen = Set<String>()

        // 按 `Package [xxx]` 分段，段首即包名，绝不再从路径切包。
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

        let componentPattern = #"([a-zA-Z0-9_]+(?:\.[a-zA-Z0-9_]+)+)/([a-zA-Z0-9_.$]+)"#
        let regex = try? NSRegularExpression(pattern: componentPattern)

        for seg in segments {
            let pkg = seg.pkg
            let body = seg.lines
            var hasBootPerm = false
            var components: [(String, Bool)] = []

            for (i, line) in body.enumerated() {
                if line.contains("RECEIVE_BOOT_COMPLETED") {
                    // granted=false 视为无权限；其余（granted=true 或未标注）视为有
                    hasBootPerm = !line.contains("granted=false")
                }
                guard line.contains("android.intent.action.BOOT_COMPLETED") else { continue }
                let lo = max(0, i - 4)
                let hi = min(body.count - 1, i + 4)
                let window = body[lo...hi].joined(separator: "\n")
                guard let regex,
                      let m = regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
                      let r = Range(m.range, in: window) else { continue }
                let matched = String(window[r])
                let parts = matched.split(separator: "/", maxSplits: 1)
                var comp: String
                if parts.count == 2 {
                    let owner = String(parts[0])
                    let cls = String(parts[1])
                    // 若匹配到的 owner 不是本包（正则可能抓到相邻包），用本包名归一
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

            // 有 BOOT_COMPLETED 接收器组件，或有权限声明，都纳入结果（兼容只报权限的固件）
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
        return result
    }

    /// 从 dumpsys 的 `Package [com.foo] (...)` 行提取包名
    private static func packageName(from line: String) -> String? {
        guard line.hasPrefix("Package [") else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let start = line.index(line.startIndex, offsetBy: 9)
        let pkg = String(line[start..<close]).trimmingCharacters(in: .whitespaces)
        // 合法 Android 包名至少含一个点
        return pkg.contains(".") ? pkg : nil
    }

    private func displayComponent(_ entry: AutostartEntry) -> String {
        let parts = entry.component.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return entry.component }
        let owner = String(parts[0])
        let name = labels[owner] ?? owner
        return "\(name)/\(parts[1])"
    }

    private func toggle(_ entry: AutostartEntry) {
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
            } catch {
                err = error.localizedDescription
                client.disconnect()
            }
            DispatchQueue.main.async {
                if err.isEmpty {
                    self.load()
                } else {
                    UIKitHelper.alert("失败", err, in: self)
                }
            }
        }
    }
}

extension AutostartViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let e = entries[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = displayComponent(e)
        cfg.secondaryText = e.enabled ? "已启用 · 开机会自启" : "已禁用"
        cfg.secondaryTextProperties.color = e.enabled ? .systemGreen : .secondaryLabel
        cfg.image = UIImage(systemName: e.enabled ? "bolt.fill" : "bolt.slash")
        cfg.imageProperties.tintColor = e.enabled ? .systemOrange : .secondaryLabel
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = "\(displayComponent(e))，\(e.enabled ? "已启用开机自启" : "已禁用开机自启")"
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let e = entries[indexPath.row]
        UIKitHelper.confirm(e.enabled ? "禁用自启" : "启用自启", displayComponent(e), in: self, destructive: e.enabled) {
            self.toggle(e)
        }
    }
}

import UIKit

/// 自启管理页：列出具备 BOOT_COMPLETED 的应用，启用/禁用其开机接收器
final class AutostartViewController: UIViewController {

    private let host: AdbHost
    private var entries: [AutostartEntry] = []

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.textAlignment = .center; l.numberOfLines = 0; return l
    }()

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.dataSource = self; tableView.delegate = self
        tableView.tableHeaderView = statusLabel
        tableView.refreshControl = refresh
        refresh.addTarget(self, action: #selector(load), for: .valueChanged)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        load()
    }

    @objc private func load() {
        statusLabel.text = "正在分析自启项（逐个 dumpsys，可能较慢）…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var result: [AutostartEntry] = []; var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                let pkgsOut = try client.shell("pm list packages -f", timeout: 90)
                var userPkgs: [String] = []
                for line in pkgsOut.split(separator: "\n") {
                    let s = line.trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix("package:/data"), let eq = s.firstIndex(of: "=") else { continue }
                    let pkg = String(s[s.index(after: eq)...])
                    if !pkg.isEmpty { userPkgs.append(pkg) }
                }
                for pkg in userPkgs.prefix(300) {
                    guard let dump = try? client.shell("dumpsys package \(pkg)", timeout: 15) else { continue }
                    let comps = Self.parseBootReceivers(dump, pkg)
                    for c in comps {
                        result.append(AutostartEntry(pkg: pkg, component: c.0, enabled: c.1))
                    }
                }
                client.disconnect()
            } catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                self.entries = result
                self.statusLabel.text = err.isEmpty
                    ? (result.isEmpty ? "未发现开机自启项" : "发现 \(result.count) 个自启项 · 点按切换启用/禁用")
                    : err
                self.tableView.reloadData()
                self.refresh.endRefreshing()
            }
        }
    }

    /// 解析 dumpsys package 中 BOOT_COMPLETED 附近的组件与其 enabled 状态
    private static func parseBootReceivers(_ dump: String, _ pkg: String) -> [(String, Bool)] {
        let lines = dump.split(separator: "\n").map(String.init)
        var out: [(String, Bool)] = []
        var seen = Set<String>()
        for i in lines.indices {
            guard lines[i].contains("android.intent.action.BOOT_COMPLETED") else { continue }
            let lo = max(0, i - 5), hi = min(lines.count - 1, i + 5)
            let window = lines[lo...hi].joined(separator: "\n")
            // 找 pkg/Component 形式
            let pattern = #"([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: window, range: NSRange(window.startIndex..., in: window)),
                  let r = Range(m.range, in: window) else { continue }
            var comp = String(window[r])
            let seg = comp.split(separator: "/")
            if seg.count == 2, seg[0] != pkg, !seg[1].contains(".") { comp = "\(pkg)/\(seg[1])" }
            guard !seen.contains(comp) else { continue }
            seen.insert(comp)
            let enabled = !window.contains("enabled=false")
            out.append((comp, enabled))
        }
        return out
    }

    private func toggle(_ entry: AutostartEntry) {
        let cmd = entry.enabled ? "pm disable \(entry.component)" : "pm enable \(entry.component)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var err = ""
            do { try client.connect(host: self.host.ip, port: self.host.port); _ = try client.shell(cmd, timeout: 30); client.disconnect() }
            catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                if err.isEmpty { self.load() } else { UIKitHelper.alert("失败", err, in: self) }
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
        cfg.text = e.component
        cfg.secondaryText = e.enabled ? "已启用（开机会自启）" : "已禁用"
        cfg.secondaryTextProperties.color = e.enabled ? .systemGreen : .secondaryLabel
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let e = entries[indexPath.row]
        UIKitHelper.confirm(e.enabled ? "禁用自启" : "启用自启", "\(e.component)", in: self, destructive: e.enabled) {
            self.toggle(e)
        }
    }
}

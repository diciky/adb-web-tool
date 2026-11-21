import UIKit

/// 进程占用：`top -n 2 -d 1 -b` 两次刷新取第二屏，得到 1 秒间隔的瞬时 CPU。
/// 已在 BRAVIA Android 9（toybox top）真机实测列格式：
///   PID USER PR NI VIRT RES SHR S[%CPU] %MEM TIME+ ARGS
/// RES 为人类可读单位（352M / 1.0G / 数字=KB）。应用进程按 USER 前缀 u0_a 识别。

// MARK: - 采集与解析

struct ProcessSample {
    struct Proc {
        let pid: Int
        let user: String
        let state: String        // R/S/D/Z/T（toybox 状态首字符）
        let cpu: Double
        let memBytes: Int64      // RES 换算为字节
        let args: String         // 原始命令行（可能是包名）
        var pkg: String?         // 应用进程 → 主包名（去 :sub 后缀）
        var isApp: Bool { user.hasPrefix("u0_a") }
    }

    var procs: [Proc] = []       // top 原始顺序（CPU 降序）
    var totalTasks: Int = 0
    var running: Int = 0
    var zombie: Int = 0
}

enum ProcessProbe {

    static func fetch(ip: String, port: UInt16) throws -> ProcessSample {
        let client = AdbClient()
        defer { client.disconnect() }
        try client.connect(host: ip, port: port)
        let out = try client.shell("top -n 2 -d 1 -b", timeout: 45)
        return parse(out)
    }

    static func forceStop(ip: String, port: UInt16, pkg: String) throws {
        let client = AdbClient()
        defer { client.disconnect() }
        try client.connect(host: ip, port: port)
        _ = try client.shell("am force-stop \(pkg)", timeout: 30)
    }

    // MARK: 解析

    static func parse(_ text: String) -> ProcessSample {
        var sample = ProcessSample()
        for line in text.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Tasks:") {
                sample.totalTasks = numberBefore(" total", in: s) ?? 0
                sample.running = numberBefore(" running", in: s) ?? 0
                sample.zombie = numberBefore(" zombie", in: s) ?? 0
            }
        }
        // 找第二屏列头行（最后一次出现的 "PID USER ... ARGS" 行）
        let lines = text.split(separator: "\n")
        guard let headerIdx = lines.lastIndex(where: {
            String($0).trimmingCharacters(in: .whitespaces).hasPrefix("PID ")
                && String($0).contains("ARGS")
        }) else { return sample }
        for raw in lines[(headerIdx + 1)...] {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("Tasks:"),
                  !line.hasPrefix("Mem:"),                   !line.hasPrefix("Swap:"),
                  !line.hasPrefix("%cpu") else { continue }
            let cols = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard cols.count >= 12, let pid = Int(cols[0]) else { continue }
            let state = String(cols[7].prefix(1))
            let cpu = Double(cols[8]) ?? 0
            let mem = parseSize(cols[5])
            let args = cols[11...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            var proc = ProcessSample.Proc(
                pid: pid, user: cols[1], state: state, cpu: cpu,
                memBytes: mem, args: args, pkg: nil
            )
            if proc.isApp {
                let first = args.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? args
                let main = first.split(separator: ":", maxSplits: 1).first.map(String.init) ?? first
                if looksLikePackage(main) { proc.pkg = main }
            }
            sample.procs.append(proc)
        }
        return sample
    }

    private static func looksLikePackage(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("["), !s.contains(" ") else { return false }
        let parts = s.split(separator: ".")
        return parts.count >= 2 && parts.allSatisfy({ !$0.isEmpty && !$0.contains(":") })
    }

    /// toybox RES/VIRT：数字=KB，352M=MB，1.0G=GB，K 同数字
    static func parseSize(_ token: String) -> Int64 {
        guard !token.isEmpty else { return 0 }
        let unit = token.last!
        let digits = token.dropLast()
        if let v = Int64(token) { return v * 1024 }
        guard let v = Double(digits) else { return 0 }
        switch unit {
        case "K", "k": return Int64(v * 1024)
        case "M", "m": return Int64(v * 1024 * 1024)
        case "G", "g": return Int64(v * 1024 * 1024 * 1024)
        default: return Int64(v)
        }
    }

    static func stateName(_ s: String) -> String {
        switch s {
        case "R": return "运行中"
        case "D": return "磁盘等待"
        case "Z": return "僵尸"
        case "T": return "已停止"
        default: return "睡眠"
        }
    }

    /// 取 key 之前紧邻的整数（如 " 373 total" → 373）。key 必须含前导空格以精确定位。
    private static func numberBefore(_ key: String, in text: String) -> Int? {
        guard let r = text.range(of: key) else { return nil }
        var digits = ""
        var idx = text.index(before: r.lowerBound)
        while text[idx].isNumber {
            digits.insert(text[idx], at: digits.startIndex)
            if idx == text.startIndex { break }
            idx = text.index(before: idx)
        }
        return Int(digits)
    }
}

// MARK: - 进程管理页

final class ProcessListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let host: AdbHost
    private var sample: ProcessSample?
    private var sortByMemory = false
    private var icons: [String: UIImage] = [:]
    private var names: [String: String] = [:]
    private var refreshing = false
    private var refreshTimer: Timer?

    private let statLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = "正在采集进程数据…"; return l
    }()
    private let sortControl: UISegmentedControl = {
        let c = UISegmentedControl(items: ["按 CPU", "按内存"])
        c.selectedSegmentIndex = 0
        return c
    }()
    private let table: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "proc")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()

    init(host: AdbHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "进程占用"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        let head = UIStackView(arrangedSubviews: [statLabel, sortControl])
        head.axis = .vertical; head.spacing = 8
        head.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)
        head.isLayoutMarginsRelativeArrangement = true

        view.addSubview(head)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            head.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: head.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        sortControl.addTarget(self, action: #selector(sortChanged), for: .valueChanged)
        table.dataSource = self
        table.delegate = self
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addTarget(self, action: #selector(manualRefresh), for: .valueChanged)
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    @objc private func sortChanged() {
        sortByMemory = sortControl.selectedSegmentIndex == 1
        table.reloadData()
    }

    @objc private func manualRefresh() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.table.refreshControl?.endRefreshing()
        }
    }

    // MARK: 采集

    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let s = (try? ProcessProbe.fetch(ip: self.host.ip, port: self.host.port)) ?? nil
            DispatchQueue.main.async {
                self.refreshing = false
                if let s {
                    self.sample = s
                    self.statLabel.text = String(
                        format: "共 %d 个进程 · 运行中 %d · 僵尸 %d · %d 个应用进程",
                        s.totalTasks, s.running, s.zombie,
                        s.procs.filter { $0.isApp }.count
                    )
                    self.table.reloadData()
                    self.resolveVisibleApps()
                } else {
                    self.statLabel.text = "采集失败 · 请确认设备已授权 ADB"
                }
            }
        }
    }

    /// 后台逐包解析未缓存的应用图标/中文名（每包独立连接，与自启页同模式）
    private func resolveVisibleApps() {
        guard let s = sample else { return }
        let pkgs = Array(Set(s.procs.compactMap { $0.pkg }).filter {
            icons[$0] == nil && AppLabelResolver.isResolved(pkg: $0)
        })
        let unresolved = Array(Set(s.procs.compactMap { $0.pkg }).filter {
            icons[$0] == nil && !AppLabelResolver.isResolved(pkg: $0)
        })
        // 先刷缓存命中的
        for pkg in pkgs {
            if let data = AppLabelResolver.cachedIcon(pkg: pkg) {
                icons[pkg] = UIImage(data: data)
            }
            names[pkg] = AppLabelResolver.cachedLabel(pkg: pkg, apkPath: "") ?? names[pkg]
        }
        table.reloadData()
        guard !unresolved.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            for pkg in unresolved {
                let client = AdbClient()
                do {
                    try client.connect(host: self.host.ip, port: self.host.port)
                    let assets = AppLabelResolver.assets(for: pkg, apkPath: "", client: client)
                    client.disconnect()
                    DispatchQueue.main.async {
                        if let label = assets.label { self.names[pkg] = label }
                        if let data = assets.iconData { self.icons[pkg] = UIImage(data: data) }
                        self.table.reloadData()
                    }
                } catch {
                    client.disconnect()
                }
            }
        }
    }

    // MARK: 列表

    private var displayRows: [ProcessSample.Proc] {
        guard let s = sample else { return [] }
        let rows = s.procs
        if sortByMemory {
            return rows.sorted { $0.memBytes > $1.memBytes }
        }
        return rows // top 原始顺序即 CPU 降序
    }

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayRows.count
    }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "proc", for: indexPath)
        let p = displayRows[indexPath.row]
        var cfg = cell.defaultContentConfiguration()

        let display: String
        if let pkg = p.pkg {
            display = names[pkg] ?? AppLabelResolver.cachedLabel(pkg: pkg, apkPath: "") ?? p.args
        } else {
            display = p.args.isEmpty ? p.user : p.args
        }
        cfg.text = display
        cfg.textProperties.numberOfLines = 1
        let mem = ByteCountFormatter.string(fromByteCount: p.memBytes, countStyle: .memory)
        cfg.secondaryText = String(
            format: "PID %d · %@ · %@ · CPU %.1f%% · 内存 %@",
            p.pid, p.user, ProcessProbe.stateName(p.state), p.cpu, mem
        )
        cfg.secondaryTextProperties.color = .secondaryLabel
        cfg.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        cell.contentConfiguration = cfg

        let img: UIImage?
        if let pkg = p.pkg, let icon = icons[pkg] {
            img = icon
        } else if let pkg = p.pkg, let data = AppLabelResolver.cachedIcon(pkg: pkg) {
            img = UIImage(data: data)
        } else if p.isApp {
            img = UIImage(systemName: "app")
        } else {
            img = UIImage(systemName: p.state == "R" ? "bolt.fill" : "gearshape.2")
        }
        let iconView = UIImageView(image: img)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        iconView.isAccessibilityElement = true
        iconView.accessibilityLabel = "进程图标"
        iconView.accessibilityTraits = .image
        cell.accessoryView = iconView

        cell.accessibilityLabel = "\(display)，\(ProcessProbe.stateName(p.state))，CPU \(Int(p.cpu))%，内存 \(mem)"
        // 应用进程可强制停止
        cell.selectionStyle = p.pkg != nil ? .default : .none
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        guard let p = displayRows[safe: indexPath.row], let pkg = p.pkg else { return }
        let name = names[pkg] ?? p.args
        let ac = UIAlertController(
            title: "强制停止「\(name)」",
            message: "将结束该应用的所有进程，未保存的数据会丢失。对电视上的应用可随时重新启动。",
            preferredStyle: .alert
        )
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        ac.addAction(UIAlertAction(title: "强制停止", style: .destructive) { [weak self] _ in
            self?.forceStop(pkg: pkg)
        })
        present(ac, animated: true)
    }

    private func forceStop(pkg: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try ProcessProbe.forceStop(ip: self.host.ip, port: self.host.port, pkg: pkg)
                DispatchQueue.main.async { self.refresh() }
            } catch {
                DispatchQueue.main.async {
                    UIKitHelper.alert("停止失败", error.localizedDescription, in: self)
                }
            }
        }
    }
}

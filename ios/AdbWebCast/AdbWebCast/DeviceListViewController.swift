import UIKit

/// 第一屏：三种设备发现方式（自动扫描 / 手动网段 / IP 直连）+ 设备列表
final class DeviceListViewController: UIViewController {

    private var hosts: [AdbHost: String] = [:]   // host -> 设备型号（异步回填）
    private var interfaces: [LocalInterface] = []
    private var scanning = false
    private var scanToken = 0

    private let titleLabel: UILabel = {
        let l = UILabel(); l.text = "ADB 电视助手"; l.font = .boldSystemFont(ofSize: 22); return l
    }()
    private let subtitleLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = "自动扫描 / 手动网段 / IP 直连，发现局域网内的 ADB 电视"; return l
    }()
    private let netLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.numberOfLines = 0; return l
    }()
    private let autoButton: UIButton = DeviceListViewController.makeButton("自动扫描本机网段", .systemBlue)
    private let manualButton: UIButton = DeviceListViewController.makeButton("手动输入网段", .systemTeal)
    private let directButton: UIButton = DeviceListViewController.makeButton("输入电视 IP 直连", .systemPurple)

    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.dataSource = self; t.delegate = self; t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let emptyLabel: UILabel = {
        let l = UILabel(); l.text = "尚未发现设备\n用上方任一方式开始发现"
        l.textColor = .tertiaryLabel; l.textAlignment = .center; l.numberOfLines = 0
        l.font = .systemFont(ofSize: 15); return l
    }()

    private static func makeButton(_ title: String, _ color: UIColor) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 14)
        b.backgroundColor = color
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 9
        b.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return b
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        refreshNetworkInfo()
    }

    private func buildUI() {
        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, netLabel, autoButton, manualButton, directButton])
        header.axis = .vertical; header.spacing = 8; header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header); view.addSubview(tableView)
        tableView.refreshControl = refresh
        refresh.addTarget(self, action: #selector(autoScan), for: .valueChanged)
        autoButton.addTarget(self, action: #selector(autoScan), for: .touchUpInside)
        manualButton.addTarget(self, action: #selector(manualSubnet), for: .touchUpInside)
        directButton.addTarget(self, action: #selector(directIP), for: .touchUpInside)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func refreshNetworkInfo() {
        interfaces = LanScanner.localInterfaces()
        if interfaces.isEmpty {
            netLabel.text = "⚠️ 未检测到本机 WiFi/以太网 IP（已自动忽略 VPN/蜂窝网卡）。可直接用「手动网段」或「IP 直连」。"
        } else {
            let lines = interfaces.map { "• \($0.name)  \($0.ip)" }
            netLabel.text = "本机网卡：\n" + lines.joined(separator: "\n")
        }
    }

    // MARK: 三种发现方式

    @objc private func autoScan() {
        guard !scanning else { return }
        refreshNetworkInfo()
        let bases = interfaces.compactMap { LanScanner.subnetBase(of: $0.ip) }
        if bases.isEmpty {
            UIKitHelper.alert("无法自动扫描", "未检测到可用的本机网卡 IP，请用「手动输入网段」或「IP 直连」。", in: self)
            refresh.endRefreshing()
            return
        }
        startScan(bases: bases, singleIPs: [], label: "自动扫描")
    }

    @objc private func manualSubnet() {
        UIKitHelper.input("输入要扫描的网段", placeholder: "例如 10.10.10", in: self) { [weak self] text in
            guard let self else { return }
            let base = text.trimmingCharacters(in: .whitespaces)
            // 支持用户输入完整 IP 或 10.10.10.0/24 形式，提取前三段
            let candidates = base.split(separator: ".").compactMap { Int($0) }
            guard candidates.count >= 3, candidates.prefix(3).allSatisfy({ $0 >= 0 && $0 <= 255 }) else {
                UIKitHelper.alert("网段格式不对", "请输入形如 10.10.10 的前三段。", in: self); return
            }
            self.startScan(bases: ["\(candidates[0]).\(candidates[1]).\(candidates[2])"], singleIPs: [], label: "网段 \(base)")
        }
    }

    @objc private func directIP() {
        UIKitHelper.input("输入电视 IP", placeholder: "例如 10.10.10.121", in: self) { [weak self] text in
            guard let self else { return }
            let ip = text.trimmingCharacters(in: .whitespaces)
            guard LanScanner.validIPv4(ip) else {
                UIKitHelper.alert("IP 格式不对", "请输入形如 10.10.10.121 的合法 IPv4 地址。", in: self); return
            }
            self.startScan(bases: [], singleIPs: [ip], label: "直连 \(ip)")
        }
    }

    private func startScan(bases: [String], singleIPs: [String], label: String) {
        guard !scanning else { return }
        scanning = true
        scanToken += 1
        let token = scanToken
        hosts.removeAll()
        tableView.reloadData()
        updateEmpty()
        autoButton.setTitle("扫描中…（\(label)）", for: .normal)
        autoButton.isEnabled = false
        autoButton.alpha = 0.6
        LanScanner.scan(bases: bases, singleIPs: singleIPs) { [weak self] host in
            guard let self, self.scanToken == token else { return }
            if self.hosts[host] == nil {
                self.hosts[host] = ""
                self.tableView.reloadData()
                self.updateEmpty()
                self.fetchModel(for: host, token: token)
            }
        } onDone: { [weak self] _ in
            guard let self, self.scanToken == token else { return }
            self.scanning = false
            self.autoButton.setTitle("自动扫描本机网段", for: .normal)
            self.autoButton.isEnabled = true
            self.autoButton.alpha = 1
            self.refresh.endRefreshing()
            self.updateEmpty()
            if self.hosts.isEmpty {
                UIKitHelper.alert("未发现设备", "确认：①电视已开启 ADB 调试且端口 5555 开放；②手机与电视在同一网段（或 IP 直连填对）；③首次连接需在电视上点「允许」。", in: self)
            }
        }
    }

    /// 连接设备读取型号，回填列表（只读，失败静默）
    private func fetchModel(for host: AdbHost, token: Int) {
        DispatchQueue.global(qos: .utility).async {
            let client = AdbClient()
            do {
                try client.connect(host: host.ip, port: host.port)
                let model = client.deviceModel()
                client.disconnect()
                guard !model.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanToken == token else { return }
                    self.hosts[host] = model
                    self.tableView.reloadData()
                }
            } catch { client.disconnect() }
        }
    }

    private func updateEmpty() { tableView.backgroundView = hosts.isEmpty ? emptyLabel : nil }
}

// MARK: - UITableView
extension DeviceListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { hosts.count }
    func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        hosts.isEmpty ? nil : "发现 \(hosts.count) 台设备（点击进入功能面板）"
    }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let host = Array(hosts.keys)[indexPath.row]
        let model = hosts[host] ?? ""
        cell.textLabel?.text = model.isEmpty ? host.serial : "\(model)  ·  \(host.serial)"
        cell.textLabel?.font = .systemFont(ofSize: 15)
        cell.imageView?.image = UIImage(systemName: "tv")
        cell.imageView?.tintColor = .systemBlue
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let host = Array(hosts.keys)[indexPath.row]
        let vc = DeviceHomeViewController(host: host, deviceModel: hosts[host] ?? "")
        navigationController?.pushViewController(vc, animated: true)
    }
}

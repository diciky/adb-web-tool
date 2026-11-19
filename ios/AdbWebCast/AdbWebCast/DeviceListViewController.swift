import UIKit

/// 第一屏：显示本机网段、扫描开关,以及扫描到的 ADB 设备列表。
final class DeviceListViewController: UIViewController {

    private var hosts: [AdbHost: String] = [:]   // host -> 设备型号（型号异步回填）
    private var interfaces: [LocalInterface] = []
    private var scanning = false
    private var scanToken = 0                    // 防止旧扫描结果落到新一轮

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "ADB 电视助手"
        l.font = .boldSystemFont(ofSize: 22)
        return l
    }()
    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.text = "适配当前 WiFi / 热点网段，自动发现局域网内的 ADB 电视"
        return l
    }()
    private let netLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }()
    private let scanButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("扫描局域网", for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 15)
        b.backgroundColor = UIColor.systemBlue
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }()
    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.dataSource = self
        t.delegate = self
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let emptyLabel: UILabel = {
        let l = UILabel()
        l.text = "尚未发现设备\n点击「扫描局域网」开始"
        l.textColor = .tertiaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 15)
        return l
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        refreshNetworkInfo()
        startScan()
    }

    private func buildUI() {
        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, netLabel, scanButton])
        header.axis = .vertical
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(tableView)
        tableView.refreshControl = refresh
        refresh.addTarget(self, action: #selector(startScan), for: .valueChanged)
        scanButton.addTarget(self, action: #selector(startScan), for: .touchUpInside)

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
            netLabel.text = "⚠️ 未检测到本机 IP，请确认已连接 WiFi 或开启热点"
        } else {
            let lines = interfaces.map { "• \($0.name)  \($0.ip)  掩码 \($0.netmask)" }
            netLabel.text = "本机接口：\n" + lines.joined(separator: "\n")
        }
    }

    @objc private func startScan() {
        guard !scanning else { return }
        scanning = true
        scanToken += 1
        let token = scanToken
        hosts.removeAll()
        tableView.reloadData()
        updateEmpty()
        scanButton.setTitle("扫描中…", for: .normal)
        scanButton.isEnabled = false
        scanButton.alpha = 0.6
        refreshNetworkInfo()

        LanScanner.scanLocalNetwork { [weak self] host in
            guard let self, self.scanToken == token else { return }
            if self.hosts[host] == nil {
                self.hosts[host] = ""
                self.tableView.reloadData()
                self.updateEmpty()
                self.fetchModel(for: host, token: token)
            }
        } onDone: { [weak self] _, _ in
            guard let self, self.scanToken == token else { return }
            self.scanning = false
            self.scanButton.setTitle("重新扫描", for: .normal)
            self.scanButton.isEnabled = true
            self.scanButton.alpha = 1
            self.refresh.endRefreshing()
            self.updateEmpty()
        }
    }

    /// 连接设备读取型号，回填到列表（只读操作，失败静默）
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
            } catch {
                client.disconnect()
            }
        }
    }

    private func updateEmpty() {
        if hosts.isEmpty {
            tableView.backgroundView = emptyLabel
        } else {
            tableView.backgroundView = nil
        }
    }

    private func alert(_ title: String, _ msg: String) {
        let c = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        c.addAction(UIAlertAction(title: "好", style: .default))
        present(c, animated: true)
    }
}

// MARK: - UITableView
extension DeviceListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { hosts.count }

    func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        hosts.isEmpty ? nil : "发现 \(hosts.count) 台设备（点击安装 APK）"
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
        let vc = InstallViewController(host: host, deviceModel: hosts[host] ?? "")
        navigationController?.pushViewController(vc, animated: true)
    }
}

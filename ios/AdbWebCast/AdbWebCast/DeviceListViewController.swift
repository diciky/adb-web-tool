import UIKit

/// 第一屏：已保存设备 + 三种发现方式（自动扫描 / 手动网段 / IP 直连）
final class DeviceListViewController: UIViewController {

    private var hosts: [AdbHost: String] = [:]   // 本次扫描发现 host -> 型号（异步回填）
    private var saved: [SavedDevice] = []        // 本地记住的设备
    private var interfaces: [LocalInterface] = []
    private var scanning = false
    private var scanToken = 0
    private var bonjour: AdbBonjourBrowser?

    private let titleLabel: UILabel = {
        let l = UILabel(); l.text = "ADB 电视助手"; l.font = .boldSystemFont(ofSize: 22); return l
    }()
    private let subtitleLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = "连过一次即永久记住 · 自动扫描 / 手动网段 / IP 直连 / 配对码"; return l
    }()
    private let netLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.numberOfLines = 0; return l
    }()
    private let autoButton: UIButton = DeviceListViewController.makeButton("自动扫描本机网段", .systemBlue)
    private let manualButton: UIButton = DeviceListViewController.makeButton("手动输入网段", .systemTeal)
    private let directButton: UIButton = DeviceListViewController.makeButton("输入电视 IP 直连", .systemPurple)
    private let pairButton: UIButton = DeviceListViewController.makeButton("无线调试配对（配对码）", .systemOrange)

    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.dataSource = self; t.delegate = self; t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let emptyLabel: UILabel = {
        let l = UILabel(); l.text = "尚未发现设备\n连过一次的电视会自动显示在这里\n也可用上方任一方式开始发现"
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        saved = DeviceStore.all()
        tableView.reloadData()
        updateEmpty()
    }

    private func buildUI() {
        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, netLabel, autoButton, manualButton, directButton, pairButton])
        header.axis = .vertical; header.spacing = 8; header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header); view.addSubview(tableView)
        tableView.refreshControl = refresh
        refresh.addTarget(self, action: #selector(autoScan), for: .valueChanged)
        autoButton.addTarget(self, action: #selector(autoScan), for: .touchUpInside)
        manualButton.addTarget(self, action: #selector(manualSubnet), for: .touchUpInside)
        directButton.addTarget(self, action: #selector(directIP), for: .touchUpInside)
        pairButton.addTarget(self, action: #selector(pairingCode), for: .touchUpInside)
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
            let candidates = base.split(separator: ".").compactMap { Int($0) }
            guard candidates.count >= 3, candidates.prefix(3).allSatisfy({ $0 >= 0 && $0 <= 255 }) else {
                UIKitHelper.alert("网段格式不对", "请输入形如 10.10.10 的前三段。", in: self); return
            }
            self.startScan(bases: ["\(candidates[0]).\(candidates[1]).\(candidates[2])"], singleIPs: [], label: "网段 \(base)")
        }
    }

    @objc private func directIP() {
        let ac = UIAlertController(title: "输入电视 IP 直连",
            message: "端口留空则自动尝试常见端口（5555 / 5554 / 5556-5560 / 5114 / 5037 / 62001）；\nAndroid 11+ 无线调试端口是随机的，请用配对功能或 mDNS 扫描。",
            preferredStyle: .alert)
        ac.addTextField { $0.placeholder = "电视 IP（如 10.10.10.121）"; $0.keyboardType = .decimalPad }
        ac.addTextField { $0.placeholder = "端口（可留空）"; $0.keyboardType = .numberPad }
        ac.addAction(UIAlertAction(title: "连接", style: .default) { [weak self, weak ac] _ in
            guard let self, let ac else { return }
            let ip = (ac.textFields?[0].text ?? "").trimmingCharacters(in: .whitespaces)
            var portText = (ac.textFields?[1].text ?? "").trimmingCharacters(in: .whitespaces)
            // 兼容在 IP 框里直接填 IP:端口 的一体格式
            if let colon = ip.firstIndex(of: ":") {
                portText = String(ip[ip.index(after: colon)...])
                let hostPart = String(ip[ip.startIndex..<colon])
                guard LanScanner.validIPv4(hostPart) else {
                    UIKitHelper.alert("IP 格式不对", "请输入形如 10.10.10.121 的 IPv4 地址。", in: self); return
                }
                let ports: [UInt16] = (UInt16(portText).flatMap { $0 > 0 ? $0 : nil }).map { [$0] } ?? AdbScanPorts.extended
                self.startScan(bases: [], singleIPs: [hostPart], ports: ports, label: "直连 \(ip)")
                return
            }
            guard LanScanner.validIPv4(ip) else {
                UIKitHelper.alert("IP 格式不对", "请输入形如 10.10.10.121 的 IPv4 地址。", in: self); return
            }
            let ports: [UInt16] = (UInt16(portText).flatMap { $0 > 0 ? $0 : nil }).map { [$0] } ?? AdbScanPorts.extended
            self.startScan(bases: [], singleIPs: [ip], ports: ports, label: "直连 \(ip)")
        })
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(ac, animated: true)
    }

    private func startScan(bases: [String], singleIPs: [String],
                           ports: [UInt16] = AdbScanPorts.extended, label: String) {
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
        // mDNS 动态端口（Android 11+ 无线调试）无法靠端口表扫出来，同步用 Bonjour 发现
        bonjour?.stop()
        bonjour = AdbBonjourBrowser { [weak self] ip, port, serviceType in
            guard let self, self.scanToken == token else { return }
            self.handleMdnsFound(ip: ip, port: port, serviceType: serviceType, token: token)
        }
        bonjour?.start()
        LanScanner.scan(bases: bases, singleIPs: singleIPs, ports: ports) { [weak self] host in
            guard let self, self.scanToken == token else { return }
            if self.hosts[host] == nil {
                self.hosts[host] = ""
                self.tableView.reloadData()
                self.updateEmpty()
                self.fetchModel(for: host, token: token)
            }
        } onDone: { [weak self] _ in
            guard let self, self.scanToken == token else { return }
            self.bonjour?.stop()
            self.bonjour = nil
            self.scanning = false
            self.autoButton.setTitle("自动扫描本机网段", for: .normal)
            self.autoButton.isEnabled = true
            self.autoButton.alpha = 1
            self.refresh.endRefreshing()
            self.updateEmpty()
            if self.hosts.isEmpty {
                UIKitHelper.alert(
                    "未发现设备",
                    "确认：①电视已开启 ADB 调试且网络端口开放；②手机与电视在同一网段（或 IP 直连填对，可带端口如 10.10.10.28:5556）；③首次连接需在电视上点「允许」。已自动尝试 5555 / 5554 / 5556-5560 / 5114 / 5037 / 62001 端口，并通过 mDNS 发现无线调试设备。",
                    in: self
                )
            }
        }
    }

    /// 连接设备读取型号并记住（只读，失败静默）
    private func fetchModel(for host: AdbHost, token: Int) {
        DispatchQueue.global(qos: .utility).async {
            let client = AdbClient()
            do {
                try client.connect(host: host.ip, port: host.port)
                let info = client.readDeviceInfo()
                client.disconnect()
                let name = info.model
                if !name.isEmpty { DeviceStore.remember(ip: host.ip, port: host.port, name: name) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.scanToken == token else { return }
                    self.hosts[host] = name
                    self.saved = DeviceStore.all()
                    self.tableView.reloadData()
                }
            } catch { client.disconnect() }
        }
    }

    /// mDNS 发现的设备：_adb-tls-connect 是 Android 11+ 无线调试（TLS-only adbd），连接必须走 TLS
    private func handleMdnsFound(ip: String, port: UInt16, serviceType: String, token: Int) {
        if serviceType.contains("_adb-tls-connect") {
            AdbClient.setTLSRequired(ip, required: true)
        }
        let host = AdbHost(ip: ip, port: port)
        if self.hosts[host] == nil {
            self.hosts[host] = ""
            self.tableView.reloadData()
            self.updateEmpty()
            self.fetchModel(for: host, token: token)
        }
    }

    // MARK: 无线调试配对（Android 11+ 配对码）

    @objc private func pairingCode() {
        let ac = UIAlertController(title: "无线调试配对",
            message: "电视 → 开发者选项 → 无线调试 → 使用配对码配对设备：\n① 先点下方「查找配对端口」自动填充 IP/端口（配对弹窗打开期间才有效）\n② 输入电视上显示的 6 位配对码\n③ 点「配对」",
            preferredStyle: .alert)
        ac.addTextField { $0.placeholder = "电视 IP（如 10.10.10.121）"; $0.keyboardType = .decimalPad }
        ac.addTextField { $0.placeholder = "配对端口（弹窗里的端口，非 5555）"; $0.keyboardType = .numberPad }
        ac.addTextField { $0.placeholder = "6 位配对码"; $0.keyboardType = .numberPad }
        ac.addAction(UIAlertAction(title: "查找配对端口", style: .default) { [weak self, weak ac] _ in
            self?.findPairingService(alert: ac)
        })
        ac.addAction(UIAlertAction(title: "配对", style: .default) { [weak self, weak ac] _ in
            guard let self, let ac else { return }
            let ip = (ac.textFields?[0].text ?? "").trimmingCharacters(in: .whitespaces)
            let portText = (ac.textFields?[1].text ?? "").trimmingCharacters(in: .whitespaces)
            let code = (ac.textFields?[2].text ?? "").trimmingCharacters(in: .whitespaces)
            guard LanScanner.validIPv4(ip), let port = UInt16(portText), port > 0 else {
                UIKitHelper.alert("信息不完整", "请填写电视 IP 和配对弹窗显示的端口。", in: self); return
            }
            self.runPairing(ip: ip, port: port, code: code)
        })
        ac.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(ac, animated: true)
    }

    /// 自动查找正在配对模式的设备（_adb-tls-pairing._tcp）并回填 IP/端口
    private func findPairingService(alert: UIAlertController?) {
        let hud = UIAlertController(title: "正在查找配对设备…",
            message: "请保持电视的配对弹窗处于打开状态（最多 10 秒）", preferredStyle: .alert)
        present(hud, animated: true)
        var done = false
        var pairingBrowser: AdbPairingBrowser?
        pairingBrowser = AdbPairingBrowser { [weak self, weak hud, weak pairingBrowser] ip, port in
            guard !done else { return }
            done = true
            pairingBrowser?.stop()
            DispatchQueue.main.async {
                hud?.dismiss(animated: true) {
                    alert?.textFields?[0].text = ip
                    alert?.textFields?[1].text = "\(port)"
                    self?.view.window?.makeKeyAndVisible()
                }
            }
        }
        let browser = pairingBrowser!
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak hud] in
            if !done {
                done = true
                browser.stop()
                hud?.dismiss(animated: true) {
                    guard let self else { return }
                    UIKitHelper.alert("未找到配对设备", "请确认电视的配对弹窗正在显示，再重试。", in: self)
                }
            }
        }
    }

    /// 执行配对；成功后登记 TLS、尝试发现无线调试端口并记住设备
    private func runPairing(ip: String, port: UInt16, code: String) {
        let hud = UIAlertController(title: "配对中…", message: "正在与电视交换密钥", preferredStyle: .alert)
        present(hud, animated: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let guid = try PairingClient.pair(host: ip, port: port, code: code) { text in
                    DispatchQueue.main.async { hud.message = text }
                }
                AdbClient.setTLSRequired(ip, required: true)
                DispatchQueue.main.async {
                    hud.dismiss(animated: true) {
                        self?.afterPairing(ip: ip, guid: guid)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    hud.dismiss(animated: true) {
                        guard let self else { return }
                        UIKitHelper.alert("配对失败", error.localizedDescription + "\n\n常见原因：配对码输错、配对弹窗已关闭、端口填错（要用配对弹窗里的端口，不是 5555）。", in: self)
                    }
                }
            }
        }
    }

    /// 配对成功：找无线调试端口（mDNS），连上并记住设备
    private func afterPairing(ip: String, guid: String) {
        let hud = UIAlertController(title: "配对成功 ✓",
            message: "设备 GUID：\(guid)\n正在查找无线调试端口…", preferredStyle: .alert)
        present(hud, animated: true)
        var done = false
        var tlsBrowser: AdbBonjourBrowser?
        tlsBrowser = AdbBonjourBrowser(serviceTypes: ["_adb-tls-connect._tcp."]) { [weak self, weak hud, weak tlsBrowser] foundIp, foundPort, _ in
            guard foundIp == ip, !done else { return }
            done = true
            tlsBrowser?.stop()
            DispatchQueue.main.async {
                self?.connectAfterPairing(ip: foundIp, port: foundPort, guid: guid, hud: hud)
            }
        }
        let browser = tlsBrowser!
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak hud] in
            if !done {
                done = true
                browser.stop()
                hud?.dismiss(animated: true) {
                    guard let self else { return }
                    UIKitHelper.alert("配对成功，但未找到无线调试端口",
                        "请回到首页重新扫描（自动扫描本机网段），新发现的无线调试设备可直接连接。", in: self)
                }
            }
        }
    }

    private func connectAfterPairing(ip: String, port: UInt16, guid: String, hud: UIAlertController?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var model = ""
            var ok = false
            let client = AdbClient()
            do {
                try client.connect(host: ip, port: port)
                let info = client.readDeviceInfo()
                model = info.model
                ok = true
            } catch {
                AdbLog.log("配对后连接失败：\(error.localizedDescription)", level: "W")
            }
            DispatchQueue.main.async {
                if ok && !model.isEmpty {
                    DeviceStore.remember(ip: ip, port: port, name: model)
                    if let self {
                        hud?.dismiss(animated: true) {
                            self.openDevice(AdbHost(ip: ip, port: port), model: model)
                        }
                    }
                } else {
                    hud?.dismiss(animated: true) {
                        if let self {
                            UIKitHelper.alert("配对成功，连接未就绪",
                                "设备已记住（GUID \(guid)）。无线调试端口会变动，请回首页重新扫描后连接。", in: self)
                        }
                    }
                }
                self?.saved = DeviceStore.all()
                self?.tableView.reloadData()
            }
        }
    }

    private func updateEmpty() { tableView.backgroundView = (hosts.isEmpty && saved.isEmpty) ? emptyLabel : nil }

    private func openDevice(_ host: AdbHost, model: String) {
        let vc = DeviceHomeViewController(host: host, deviceModel: model)
        navigationController?.pushViewController(vc, animated: true)
    }
}

// MARK: - UITableView
extension DeviceListViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? saved.count : hosts.count
    }
    func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return saved.isEmpty ? nil : "已记住的设备（点击直连 · 长按改名）" }
        return hosts.isEmpty ? nil : "本次发现 \(hosts.count) 台"
    }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if indexPath.section == 0 {
            let d = saved[indexPath.row]
            cell.textLabel?.text = d.displayName.isEmpty ? d.ip : "\(d.displayName)  ·  \(d.ip)"
            cell.detailTextLabel?.text = "\(d.ip):\(d.port)"
            cell.imageView?.image = UIImage(systemName: "tv.circle.fill")
            cell.imageView?.tintColor = .systemGreen
        } else {
            let host = Array(hosts.keys)[indexPath.row]
            let model = hosts[host] ?? ""
            cell.textLabel?.text = model.isEmpty ? host.serial : "\(model)  ·  \(host.serial)"
            cell.detailTextLabel?.text = "\(host.ip):\(host.port)"
            cell.imageView?.image = UIImage(systemName: "tv")
            cell.imageView?.tintColor = .systemBlue
        }
        cell.textLabel?.font = .systemFont(ofSize: 15)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let d = saved[indexPath.row]
            openDevice(AdbHost(ip: d.ip, port: d.port), model: d.displayName)
        } else {
            let host = Array(hosts.keys)[indexPath.row]
            openDevice(host, model: hosts[host] ?? "")
        }
    }
    func tableView(_ tv: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0 else { return nil }
        let d = saved[indexPath.row]
        let del = UIContextualAction(style: .destructive, title: "忘记") { [weak self] _, _, done in
            DeviceStore.remove(ip: d.ip, port: d.port)
            self?.saved = DeviceStore.all(); self?.tableView.reloadData(); self?.updateEmpty()
            done(true)
        }
        let rename = UIContextualAction(style: .normal, title: "改名") { [weak self] _, _, done in
            guard let self else { done(true); return }
            UIKitHelper.input("设备备注名", placeholder: "例如 客厅电视", current: d.alias, in: self) { name in
                DeviceStore.rename(ip: d.ip, port: d.port, alias: name)
                self.saved = DeviceStore.all(); self.tableView.reloadData()
            }
            done(true)
        }
        rename.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [del, rename])
    }
}

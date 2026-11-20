import UIKit

/// 设备信息页（第一 Tab）：顶部功能宫格（工具箱/自启/批量/日志）+ 设备信息列表
final class InfoViewController: UIViewController {

    private let host: AdbHost
    private let deviceModel: String
    private var info = DeviceInfo()
    private var rows: [(String, String)] = []

    /// 功能宫格：所有功能一击直达，工具箱内的功能全部平铺（不再折叠）
    private static let features: [(String, String, String)] = [
        ("📷", "屏幕：截图 / 实时", "截图预览、保存、实时查看电视画面"),
        ("⏻", "电源操作", "重启 / 关机 / 息屏 / 唤醒"),
        ("⌨️", "输入文字 / 剪贴板", "中文、英文统一输入；支持手机剪贴板粘贴与历史"),
        ("🖥️", "Shell 命令", "直接执行任意 shell 命令"),
        ("⚡", "自启管理", "查看与配置开机自启应用"),
        ("📦", "批量安装", "多 APK 批量推送到电视"),
        ("📝", "运行日志", "协议调试日志 · 可复制分享"),
    ]

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        l.textAlignment = .center; l.text = "读取设备信息中…"; return l
    }()

    init(host: AdbHost, deviceModel: String) {
        self.host = host; self.deviceModel = deviceModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
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
        statusLabel.text = "读取设备信息中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var d = DeviceInfo()
            var errMsg = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                d = client.readDeviceInfo()
                d.ip = self.host.ip
                // 连上即记住设备与型号，下次无需重新扫描。
                if !d.model.isEmpty { DeviceStore.remember(ip: self.host.ip, port: self.host.port, name: d.model) }
            } catch {
                client.invalidate()
                errMsg = error.localizedDescription
            }
            let rows: [(String, String)] = [
                ("型号", d.model.isEmpty ? self.deviceModel : d.model),
                ("品牌", d.brand), ("厂商", d.manufacturer),
                ("Android 版本", d.androidVersion.isEmpty ? "" : "\(d.androidVersion) (SDK \(d.sdk))"),
                ("序列号", d.serialno), ("CPU 平台", d.cpu),
                ("分辨率", d.resolution), ("电量", d.battery.isEmpty ? "" : d.battery + " %"),
                ("ADB 地址", "\(self.host.ip):\(self.host.port)"),
            ]
            DispatchQueue.main.async {
                self.info = d
                self.rows = rows
                self.statusLabel.text = d.model.isEmpty
                    ? (errMsg.isEmpty
                        ? "⚠️ 未能读取数据，请确认电视已授权 ADB 调试后下拉刷新"
                        : "⚠️ \(errMsg)（下拉刷新重试）")
                    : "已连接 · 下拉刷新"
                self.tableView.reloadData()
                self.refresh.endRefreshing()
            }
        }
    }

    private func openFeature(_ row: Int) {
        switch row {
        case 0:
            navigationController?.pushViewController(ScreenViewController(host: host), animated: true)
        case 1: powerAction()
        case 2:
            navigationController?.pushViewController(TextInputViewController(host: host), animated: true)
        case 3:
            navigationController?.pushViewController(ShellViewController(host: host), animated: true)
        case 4:
            navigationController?.pushViewController(AutostartViewController(host: host), animated: true)
        case 5:
            navigationController?.pushViewController(BatchViewController(host: host), animated: true)
        case 6:
            navigationController?.pushViewController(LogViewerViewController(), animated: true)
        default: break
        }
    }

    // MARK: 平铺的功能动作（原工具箱内迁出）

    @objc private func powerAction() {
        let sheet = UIAlertController(title: "电源操作", message: nil, preferredStyle: .actionSheet)
        [("重启", "reboot"), ("关机", "reboot -p"), ("重启到 Recovery", "reboot recovery"),
         ("休眠（息屏）", "input keyevent 223"), ("唤醒（亮屏）", "input keyevent 224")].forEach { item in
            sheet.addAction(UIAlertAction(title: item.0, style: .default) { [weak self] _ in
                self?.execCmd(item.1, msg: "已发送：\(item.0)")
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    /// 在后台线程执行一条 shell 命令，结果以状态栏提示展示
    private func execCmd(_ cmd: String, msg: String) {
        statusLabel.text = "发送中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var err = ""
            do { try client.connect(host: self.host.ip, port: self.host.port); _ = try client.shell(cmd, timeout: 30); client.disconnect() }
            catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                self.statusLabel.text = err.isEmpty ? msg : "失败：\(err)"
            }
        }
    }
}

extension InfoViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "全部功能" : "设备信息"
    }
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? InfoViewController.features.count : rows.count
    }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if indexPath.section == 0 {
            let f = InfoViewController.features[indexPath.row]
            var cfg = cell.defaultContentConfiguration()
            cfg.text = "\(f.0) \(f.1)"
            cfg.secondaryText = f.2
            cfg.secondaryTextProperties.color = .secondaryLabel
            cfg.secondaryTextProperties.lineBreakMode = .byTruncatingTail
            cell.contentConfiguration = cfg
            cell.accessoryType = .disclosureIndicator
        } else {
            let r = rows[indexPath.row]
            var cfg = cell.defaultContentConfiguration()
            cfg.text = r.0; cfg.secondaryText = r.1.isEmpty ? "—" : r.1
            cfg.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = cfg
        }
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 { openFeature(indexPath.row) }
    }
}

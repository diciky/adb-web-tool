import UIKit

/// 设备信息页（第一 Tab）：顶部功能宫格（工具箱/自启/批量/日志）+ 设备信息列表
final class InfoViewController: UIViewController {

    private let host: AdbHost
    private let deviceModel: String
    private var info = DeviceInfo()
    private var rows: [(String, String)] = []

    /// 功能宫格：所有次级功能从这里一击直达（不再塞进"更多"）
    private static let features: [(String, String, String)] = [
        ("🧰", "工具箱", "屏幕截图/实时 · 电源 · 文字输入 · 剪贴板 · Shell"),
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
            navigationController?.pushViewController(ToolsViewController(host: host), animated: true)
        case 1:
            navigationController?.pushViewController(AutostartViewController(host: host), animated: true)
        case 2:
            navigationController?.pushViewController(BatchViewController(host: host), animated: true)
        case 3:
            navigationController?.pushViewController(LogViewerViewController(), animated: true)
        default: break
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

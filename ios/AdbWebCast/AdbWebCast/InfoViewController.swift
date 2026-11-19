import UIKit

/// 设备信息页：读取 getprop / 分辨率 / 电量等
final class InfoViewController: UIViewController {

    private let host: AdbHost
    private let deviceModel: String
    private var info = DeviceInfo()
    private var rows: [(String, String)] = []

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
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                func prop(_ key: String) -> String {
                    (try? client.shell("getprop \(key)", timeout: 8))?.trimmed ?? ""
                }
                d.model = prop("ro.product.model")
                d.brand = prop("ro.product.brand")
                d.androidVersion = prop("ro.build.version.release")
                d.sdk = prop("ro.build.version.sdk")
                d.manufacturer = prop("ro.product.manufacturer")
                d.serialno = prop("ro.serialno")
                d.cpu = prop("ro.board.platform")
                d.resolution = (try? client.shell("wm size", timeout: 8))?.trimmed ?? ""
                d.battery = (try? client.shell("dumpsys battery | grep level", timeout: 8))?.trimmed ?? ""
                d.ip = self.host.ip
                client.disconnect()
            } catch {
                client.disconnect()
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
                    ? "⚠️ 未能读取数据，请确认电视已授权 ADB 调试后下拉刷新"
                    : "已连接 · 下拉刷新"
                self.tableView.reloadData()
                self.refresh.endRefreshing()
            }
        }
    }
}

extension InfoViewController: UITableViewDataSource {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let r = rows[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = r.0; cfg.secondaryText = r.1.isEmpty ? "—" : r.1
        cfg.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = cfg
        return cell
    }
}

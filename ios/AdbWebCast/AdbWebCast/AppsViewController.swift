import UIKit

/// 应用管理页：列表 / 启动 / 强制停止 / 清除数据 / 启用禁用 / 卸载
final class AppsViewController: UIViewController {

    private let host: AdbHost
    private var apps: [AppInfo] = []
    private var filtered: [AppInfo] = []
    private var showSystem = false
    private let search = UISearchController(searchResultsController: nil)

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let refresh = UIRefreshControl()
    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.textAlignment = .center; l.text = ""; return l
    }()
    private let filterButton: UIButton = {
        let b = UIButton(type: .system); b.titleLabel?.font = .systemFont(ofSize: 13)
        return b
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
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        definesPresentationContext = true

        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: filterButton)
        filterButton.addTarget(self, action: #selector(toggleFilter), for: .touchUpInside)
        updateFilterButton()

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        load()
    }

    private func updateFilterButton() {
        filterButton.setTitle(showSystem ? "仅用户应用" : "显示全部", for: .normal)
    }
    @objc private func toggleFilter() {
        showSystem.toggle(); updateFilterButton(); applyFilter()
    }

    @objc private func load() {
        statusLabel.text = "读取应用列表…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var result: [AppInfo] = []
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                let allOut = try client.shell("pm list packages -f", timeout: 90)
                let disabledOut = (try? client.shell("pm list packages -d", timeout: 30)) ?? ""
                let disabled = Set(disabledOut.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "package:", with: "") })
                let sysPrefix = ["/system", "/vendor", "/product", "/odm", "/apex", "/framework", "/system_ext"]
                var sawPathedLine = false
                for line in allOut.split(separator: "\n") {
                    let s = line.trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix("package:") else { continue }
                    // 格式：package:<路径>=<包名>。用最后一个 "=" 分割，避免路径中带 "=" 时错位。
                    guard let eq = s.lastIndex(of: "=") else { continue }
                    let path = String(s[s.index(s.startIndex, offsetBy: 8)..<eq])
                    let pkg = String(s[s.index(after: eq)...])
                    if pkg.isEmpty || path.isEmpty { continue }
                    sawPathedLine = true
                    result.append(AppInfo(pkg: pkg, path: path, name: pkg,
                                          versionName: "", isSystem: sysPrefix.contains { path.hasPrefix($0) },
                                          isDisabled: disabled.contains(pkg)))
                }
                // 兜底：部分固件的 -f 不带 APK 路径（package:com.xxx 无 "="），
                // 上面解析会得到 0 项。回退用纯包名格式再解析一次。
                if !sawPathedLine {
                    let plainOut = (try? client.shell("pm list packages", timeout: 90)) ?? ""
                    for line in plainOut.split(separator: "\n") {
                        let s = line.trimmingCharacters(in: .whitespaces)
                        guard s.hasPrefix("package:") else { continue }
                        let pkg = String(s.dropFirst(8))
                        guard !pkg.isEmpty else { continue }
                        result.append(AppInfo(pkg: pkg, path: "", name: pkg,
                                              versionName: "", isSystem: false,
                                              isDisabled: disabled.contains(pkg)))
                    }
                }
                client.disconnect()
            } catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                self.apps = result.sorted { $0.pkg < $1.pkg }
                self.applyFilter()
                self.statusLabel.text = result.isEmpty ? (err.isEmpty ? "未读取到应用" : err) : "共 \(result.count) 个应用 · 点按管理"
                self.refresh.endRefreshing()
            }
        }
    }

    private func applyFilter() {
        let q = search.searchBar.text?.trimmed.lowercased() ?? ""
        filtered = apps.filter { app in
            (showSystem || !app.isSystem) && (q.isEmpty || app.pkg.lowercased().contains(q) || app.name.lowercased().contains(q))
        }
        tableView.reloadData()
    }

    private func perform(_ cmd: String, on app: AppInfo, successMsg: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var out = ""; var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                out = try client.shell(cmd, timeout: 60); client.disconnect()
            } catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                let ok = err.isEmpty
                UIKitHelper.alert(ok ? "完成" : "失败", ok ? successMsg : err, in: self) {
                    if ok { self.load() }
                }
                _ = out
            }
        }
    }

    private func menu(for app: AppInfo) {
        let sheet = UIAlertController(title: app.name, message: app.pkg, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "启动", style: .default) { _ in
            self.perform("monkey -p \(app.pkg) -c android.intent.category.LAUNCHER 1", on: app, successMsg: "已发送启动指令")
        })
        sheet.addAction(UIAlertAction(title: "强制停止", style: .default) { _ in
            self.perform("am force-stop \(app.pkg)", on: app, successMsg: "已强制停止")
        })
        sheet.addAction(UIAlertAction(title: "清除数据", style: .destructive) { _ in
            UIKitHelper.confirm("清除数据", "确定清除 \(app.pkg) 的全部数据？", in: self) {
                self.perform("pm clear \(app.pkg)", on: app, successMsg: "已清除数据")
            }
        })
        sheet.addAction(UIAlertAction(title: app.isDisabled ? "启用" : "禁用", style: .default) { _ in
            self.perform(app.isDisabled ? "pm enable \(app.pkg)" : "pm disable \(app.pkg)", on: app,
                         successMsg: app.isDisabled ? "已启用" : "已禁用")
        })
        sheet.addAction(UIAlertAction(title: "卸载", style: .destructive) { _ in
            UIKitHelper.confirm("卸载应用", "确定卸载 \(app.pkg)？系统应用可能无法卸载。", in: self) {
                self.perform("pm uninstall \(app.pkg)", on: app, successMsg: "卸载指令已发送（系统应用可能失败）")
            }
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        present(sheet, animated: true)
    }
}

extension AppsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let a = filtered[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = a.name
        cfg.secondaryText = a.pkg + (a.isSystem ? "  · 系统" : "") + (a.isDisabled ? "  · 已禁用" : "")
        cfg.secondaryTextProperties.color = a.isDisabled ? .systemOrange : .secondaryLabel
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        menu(for: filtered[indexPath.row])
    }
}

extension AppsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) { applyFilter() }
}

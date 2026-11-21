import UIKit

/// 应用管理页：用户/系统应用切换、图标、中文名、搜索、启动/停止/清除/禁用/卸载
final class AppsViewController: UIViewController {

    private let host: AdbHost
    private var apps: [AppInfo] = []
    private var filtered: [AppInfo] = []
    private var userCount = 0
    private var systemCount = 0
    private let search = UISearchController(searchResultsController: nil)
    /// 图标内存缓存：避免滚动/切后台回前台时反复读磁盘，解析更新时按包名移除。
    private let imageCache = NSCache<NSString, UIImage>()

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
        l.adjustsFontForContentSizeCategory = true
        l.translatesAutoresizingMaskIntoConstraints = false
        l.text = ""
        return l
    }()
    private let segmented: UISegmentedControl = {
        let s = UISegmentedControl(items: ["用户应用", "系统应用"])
        s.selectedSegmentIndex = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        s.accessibilityLabel = "应用类型切换"
        return s
    }()
    private let headerView: UIView = {
        let v = UIView()
        v.backgroundColor = .clear
        return v
    }()

    private var showSystem: Bool { segmented.selectedSegmentIndex == 1 }

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从后台回前台时缓存图标可能刚补完，直接重绘当前可见行。
        tableView.reloadData()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "应用"
        view.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = refresh
        refresh.addTarget(self, action: #selector(manualRefresh), for: .valueChanged)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        definesPresentationContext = true

        statusLabel.accessibilityLabel = "应用列表状态"
        segmented.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        headerView.addSubview(statusLabel)
        headerView.addSubview(segmented)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            segmented.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            segmented.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8),
        ])
        headerView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 92)
        headerView.layoutIfNeeded()
        tableView.tableHeaderView = headerView
        updateSegmentTitles()

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        load()
    }

    private func updateSegmentTitles() {
        segmented.setTitle("用户应用 \(userCount)", forSegmentAt: 0)
        segmented.setTitle("系统应用 \(systemCount)", forSegmentAt: 1)
    }

    @objc private func segmentChanged() {
        applyFilter()
    }

    /// 下拉刷新：强制清除旧版本遗留的失败缓存（24h 重试间隔内 isResolved 会锁住），
    /// 否则从 v3.8.0 及更早版本升级的用户会一直看到纯包名列表。
    @objc private func manualRefresh() {
        load(force: true)
    }

    @objc private func load() { load(force: false) }

    private func load(force: Bool) {
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
                    guard let eq = s.lastIndex(of: "=") else { continue }
                    let path = String(s[s.index(s.startIndex, offsetBy: 8)..<eq])
                    let pkg = String(s[s.index(after: eq)...])
                    if pkg.isEmpty || path.isEmpty { continue }
                    sawPathedLine = true
                    let isSystem = sysPrefix.contains { path.hasPrefix($0) }
                    let cached = AppLabelResolver.cached(pkg: pkg)
                    result.append(AppInfo(pkg: pkg, path: path, name: cached?.label ?? pkg,
                                          versionName: "", isSystem: isSystem,
                                          isDisabled: disabled.contains(pkg)))
                }
                // 部分固件 -f 不带路径，回退纯包名；path 为空时解析阶段会用 pm path 补齐。
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
            } catch {
                err = error.localizedDescription
            }
            let sorted = sortApps(result)
            DispatchQueue.main.async {
                self.apps = sorted
                self.userCount = sorted.filter { !$0.isSystem }.count
                self.systemCount = sorted.filter { $0.isSystem }.count
                self.updateSegmentTitles()
                self.applyFilter()
                self.statusLabel.text = result.isEmpty
                    ? (err.isEmpty ? "未读取到应用" : err)
                    : "共 \(result.count) 个应用 · 正在加载名称与图标…"
                self.refresh.endRefreshing()
                // 自动兜底：用户应用一个图标都没有（旧版失败缓存锁死/首次），强制重解析。
                // 手动下拉也强制；正常刷新只解析缺失项。
                let userPkgs = result.filter { !$0.isSystem }.map { $0.pkg }
                let noIconsAtAll = !userPkgs.isEmpty
                    && userPkgs.allSatisfy { AppLabelResolver.cachedIcon(pkg: $0) == nil }
                if force || noIconsAtAll {
                    AppLabelResolver.clearIncompleteRecords(pkgs: result.map { $0.pkg })
                }
                self.resolveAssetsIfNeeded()
            }
        }
    }

    private func sortApps(_ list: [AppInfo]) -> [AppInfo] {
        list.sorted { l, r in
            if l.name != l.pkg && r.name == r.pkg { return true }
            if l.name == l.pkg && r.name != r.pkg { return false }
            return l.name.localizedStandardCompare(r.name) == .orderedAscending
        }
    }

    /// 逐个解析应用名与图标，每解析一个就回主线程刷新，用户无需等全部完成。
    private func resolveAssetsIfNeeded() {
        // 已解析过的包（包括确认没有图标的包）不再重复拉 APK；缓存按包名命中。
        let pending = apps.filter { !AppLabelResolver.isResolved(pkg: $0.pkg) }
        let targets = Array((pending.filter { !$0.isSystem } + pending.filter { $0.isSystem }).prefix(400))
        guard !targets.isEmpty else {
            if !apps.isEmpty { statusLabel.text = "共 \(apps.count) 个应用 · 点按管理" }
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var connected = false
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                connected = true
            } catch {
                AdbLog.log("应用资源解析连接失败：\(error.localizedDescription)", level: "W")
            }
            var done = 0
            var ok = 0
            for app in targets {
                guard connected else { break }
                let assets = AppLabelResolver.assets(for: app.pkg, apkPath: app.path, client: client)
                done += 1
                if assets.label != nil || assets.iconData != nil { ok += 1 }
                if assets.label != nil || assets.iconData != nil {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.apps = self.apps.map { item in
                            var copy = item
                            if item.pkg == app.pkg, let label = assets.label { copy.name = label }
                            return copy
                        }
                        self.imageCache.removeObject(forKey: app.pkg as NSString)
                        self.apps = self.sortApps(self.apps)
                        self.applyFilter()
                    }
                }
                if done % 8 == 0 || done == targets.count {
                    let finished = done
                    let total = targets.count
                    DispatchQueue.main.async { [weak self] in
                        self?.statusLabel.text = "已加载 \(finished)/\(total) 个应用资源 · 成功 \(ok)"
                    }
                }
            }
            let allDone = done
            let totalCount = targets.count
            let totalApps = self.apps.count
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = allDone >= totalCount
                    ? "共 \(totalApps) 个应用 · 点按管理"
                    : "共 \(totalApps) 个应用 · 资源加载中断（已处理 \(allDone)/\(totalCount)）"
            }
        }
    }

    private func applyFilter() {
        let q = search.searchBar.text?.trimmed.lowercased() ?? ""
        filtered = apps.filter { app in
            (showSystem || !app.isSystem)
                && (q.isEmpty || app.pkg.lowercased().contains(q) || app.name.lowercased().contains(q))
        }
        tableView.reloadData()
    }

    /// 图标读取顺序：内存 → Application Support 缓存 → 占位图。
    private func appIcon(_ app: AppInfo) -> UIImage? {
        if let cached = imageCache.object(forKey: app.pkg as NSString) { return cached }
        guard let data = AppLabelResolver.cachedIcon(pkg: app.pkg), let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: app.pkg as NSString)
        return image
    }

    /// 40×40 圆角占位图：用应用名首字，不依赖颜色单独区分。
    private func placeholderImage(_ name: String) -> UIImage {
        let size = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIColor.tertiarySystemFill.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 9).fill()
            let initial = String(name.prefix(1)).uppercased()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 19),
                .foregroundColor: UIColor.label,
            ]
            (initial as NSString).draw(in: CGRect(x: 0, y: 8, width: 40, height: 26), withAttributes: attrs)
        }
    }

    private func perform(_ cmd: String, on app: AppInfo, successMsg: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                _ = try client.shell(cmd, timeout: 60)
            } catch {
                err = error.localizedDescription
            }
            DispatchQueue.main.async {
                let ok = err.isEmpty
                UIKitHelper.alert(ok ? "完成" : "失败", ok ? successMsg : err, in: self) {
                    if ok { self.load() }
                }
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
        if let image = appIcon(a) {
            cfg.image = image.withRenderingMode(.alwaysOriginal)
        } else {
            cfg.image = placeholderImage(a.name)
        }
        cfg.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        cfg.imageProperties.cornerRadius = 9
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityLabel = "\(a.name)，\(a.pkg)\(a.isSystem ? "，系统应用" : "，用户应用")\(a.isDisabled ? "，已禁用" : "")"
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

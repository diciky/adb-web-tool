import UIKit

/// 文件传输页：浏览目录 / 上传 / 下载 / 删除 / 新建目录
final class FilesViewController: UIViewController {

    private let host: AdbHost
    private var path = "/sdcard"
    private var files: [RemoteFile] = []
    private let pathLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.numberOfLines = 1; l.lineBreakMode = .byTruncatingMiddle; return l
    }()
    private let tableView: UITableView = {
        let t = UITableView(frame: .zero)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.textAlignment = .center; return l
    }()
    private var picker = DocumentPickerHelper()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let progressLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.textAlignment = .center; l.isHidden = true; return l
    }()

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.dataSource = self; tableView.delegate = self
        let header = UIStackView(arrangedSubviews: [pathLabel, statusLabel, progress, progressLabel])
        header.axis = .vertical; header.spacing = 6
        header.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 100)
        tableView.tableHeaderView = header

        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newFolder)),
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(upload)),
        ]
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        load()
    }

    private func load() {
        pathLabel.text = "📁 \(path)"
        statusLabel.text = "读取目录…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var list: [RemoteFile] = []; var err = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                list = try client.listDir(self.path); client.disconnect()
            } catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                self.files = list
                self.statusLabel.text = err.isEmpty ? "\(list.count) 项 · 点文件夹进入" : err
                self.tableView.reloadData()
            }
        }
    }

    @objc private func newFolder() {
        UIKitHelper.input("新建文件夹", placeholder: "文件夹名", in: self) { [weak self] name in
            guard let self, !name.isEmpty else { return }
            let full = self.path.hasSuffix("/") ? self.path + name : self.path + "/" + name
            self.runShell("mkdir -p \"\(full)\"", msg: "已创建")
        }
    }

    @objc private func upload() {
        picker.onPick = { [weak self] urls in
            guard let self, let url = urls.first, let local = copyToTemp(url) else { return }
            self.showProgress(true, "准备上传…")
            DispatchQueue.global(qos: .userInitiated).async {
                let client = AdbClient()
                let remote = self.path.hasSuffix("/") ? self.path + url.lastPathComponent : self.path + "/" + url.lastPathComponent
                do {
                    try client.connect(host: self.host.ip, port: self.host.port)
                    try client.push(localURL: local, remotePath: remote) { pct in
                        DispatchQueue.main.async { self.progress.progress = Float(pct) / 100; self.progressLabel.text = "上传 \(pct)%" }
                    }
                    client.disconnect()
                    DispatchQueue.main.async { self.showProgress(false, ""); self.load() }
                } catch {
                    client.disconnect()
                    DispatchQueue.main.async { self.showProgress(false, ""); UIKitHelper.alert("上传失败", error.localizedDescription, in: self) }
                }
                try? FileManager.default.removeItem(at: local)
            }
        }
        UIKitHelper.pickFiles(in: self, multiple: false, delegate: picker)
    }

    private func download(_ file: RemoteFile) {
        showProgress(true, "准备下载…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                try client.pull(remotePath: file.path, to: tmp) { pct in
                    DispatchQueue.main.async { self.progress.progress = Float(pct) / 100; self.progressLabel.text = "下载 \(pct)%" }
                }
                client.disconnect()
                DispatchQueue.main.async {
                    self.showProgress(false, "")
                    let vc = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
                    vc.popoverPresentationController?.sourceView = self.tableView
                    self.present(vc, animated: true)
                }
            } catch {
                client.disconnect()
                DispatchQueue.main.async { self.showProgress(false, ""); UIKitHelper.alert("下载失败", error.localizedDescription, in: self) }
            }
        }
    }

    private func runShell(_ cmd: String, msg: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var err = ""
            do { try client.connect(host: self.host.ip, port: self.host.port); _ = try client.shell(cmd, timeout: 30); client.disconnect() }
            catch { err = error.localizedDescription; client.disconnect() }
            DispatchQueue.main.async {
                if err.isEmpty { self.load() } else { UIKitHelper.alert("失败", err, in: self) }
                _ = msg
            }
        }
    }

    private func showProgress(_ on: Bool, _ text: String) {
        progress.isHidden = !on
        progressLabel.isHidden = !on
        progressLabel.text = text
        progress.progress = 0
    }
}

extension FilesViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { files.count }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let f = files[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = (f.isDir ? "📁 " : "📄 ") + f.name
        cfg.secondaryText = f.isDir ? "文件夹" : ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        cfg.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let f = files[indexPath.row]
        if f.isDir { path = f.path; load() }
        else { download(f) }
    }
    func tableView(_ tv: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let f = files[indexPath.row]
        let del = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in
            guard let self else { done(true); return }
            UIKitHelper.confirm("删除", "确定删除 \(f.name)？", in: self) {
                self.runShell(f.isDir ? "rm -rf \"\(f.path)\"" : "rm -f \"\(f.path)\"", msg: "已删除")
            }
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }
}

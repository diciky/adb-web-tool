import UIKit

/// 批量操作页：对当前设备连续执行多种动作（重启/关机/息屏/清数据/卸载等）
final class BatchViewController: UIViewController {

    private let host: AdbHost
    private var selected: Set<Int> = []
    private var pkg = ""
    private let actions = BatchAction.allCases

    private let tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let runButton: UIButton = {
        let b = UIButton(type: .system); b.setTitle("执行所选操作", for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 16); b.backgroundColor = .systemBlue
        b.setTitleColor(.white, for: .normal); b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 46).isActive = true; return b
    }()
    private let resultLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = "选择要执行的操作（可多选）。涉及应用的动作需先填写包名。"; return l
    }()

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tableView.dataSource = self; tableView.delegate = self
        let wrap = UIView()
        let stack = UIStackView(arrangedSubviews: [resultLabel, runButton])
        stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: 8),
        ])
        wrap.frame = CGRect(x: 0, y: 0, width: view.frame.width, height: 130)
        tableView.tableFooterView = wrap
        runButton.addTarget(self, action: #selector(run), for: .touchUpInside)

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "设置包名", style: .plain, target: self, action: #selector(setPkg))

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func setPkg() {
        UIKitHelper.input("应用包名", placeholder: "例如 com.example.app", current: pkg, in: self) { [weak self] text in
            self?.pkg = text
            self?.resultLabel.text = text.isEmpty ? "包名未设置，涉及应用的动作将跳过。" : "应用包名：\(text)"
        }
    }

    @objc private func run() {
        guard !selected.isEmpty else {
            UIKitHelper.alert("未选择操作", "请先勾选要执行的操作。", in: self); return
        }
        let needsPkg = selected.contains { [.forceStop, .clearData, .uninstall].contains(actions[$0]) }
        if needsPkg && pkg.isEmpty {
            UIKitHelper.alert("缺少包名", "所选操作需要应用包名，请点右上角「设置包名」。", in: self); return
        }
        runButton.isEnabled = false
        resultLabel.text = "执行中…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var lines: [String] = []
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                for i in self.selected.sorted() {
                    let a = self.actions[i]
                    let cmd: String
                    switch a {
                    case .reboot: cmd = "reboot"
                    case .shutdown: cmd = "reboot -p"
                    case .recovery: cmd = "reboot recovery"
                    case .sleep: cmd = "input keyevent 223"
                    case .wake: cmd = "input keyevent 224"
                    case .forceStop: cmd = "am force-stop \(self.pkg)"
                    case .clearData: cmd = "pm clear \(self.pkg)"
                    case .uninstall: cmd = "pm uninstall \(self.pkg)"
                    }
                    do {
                        _ = try client.shell(cmd, timeout: 20)
                        lines.append("✅ \(a.rawValue)")
                    } catch { lines.append("❌ \(a.rawValue)：\(error.localizedDescription)") }
                }
                client.disconnect()
            } catch { lines.append("❌ 连接失败：\(error.localizedDescription)"); client.disconnect() }
            DispatchQueue.main.async {
                self.runButton.isEnabled = true
                self.resultLabel.text = lines.joined(separator: "\n")
            }
        }
    }
}

extension BatchViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { actions.count }
    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let a = actions[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = a.rawValue
        cell.contentConfiguration = cfg
        cell.accessoryType = selected.contains(indexPath.row) ? .checkmark : .none
        return cell
    }
    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        if selected.contains(indexPath.row) { selected.remove(indexPath.row) } else { selected.insert(indexPath.row) }
        tv.reloadRows(at: [indexPath], with: .none)
    }
}

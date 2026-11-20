import UIKit

/// 定时任务页：本地保存任务（间隔 / Cron），App 前台时按计划对当前电视执行动作。
/// 功能对齐 Web 端「批量/定时」里的定时任务；iOS 受系统限制无法在后台长期运行，
/// 因此任务在 App 打开期间轮询触发，页面顶部会明确说明。
final class ScheduleViewController: UIViewController {

    private let host: AdbHost
    private let store = ScheduleStore.shared
    private var jobs: [ScheduleJob] = []
    private let table: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()
    private let hint: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.text = "任务保存在本机，App 打开时按计划触发（iOS 不允许普通 App 后台常驻）。目标：当前连接的电视。"
        return l
    }()

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "定时任务"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addJob))

        let header = UIView()
        hint.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
        ])
        table.tableHeaderView = header
        table.dataSource = self
        table.delegate = self
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .scheduleJobsChanged, object: nil)
        reload()
        store.startTicking()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reload() {
        jobs = store.all()
        table.reloadData()
    }

    // MARK: - 添加任务

    @objc private func addJob() {
        let sheet = UIAlertController(title: "添加定时任务", message: "动作与计划", preferredStyle: .actionSheet)
        for (action, title) in ScheduleJob.actions {
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.presentEditor(action: action)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    private func presentEditor(action: String) {
        let editor = ScheduleEditorViewController(host: host, action: action) { [weak self] job in
            self?.store.add(job)
            self?.reload()
        }
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }
}

extension ScheduleViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { jobs.count }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let j = jobs[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = (j.paused ? "⏸ " : "⏰ ") + (j.name.isEmpty ? j.actionTitle : j.name)
        let plan = j.mode == "interval" ? "每 \(max(60, j.intervalSec)) 秒" : "Cron \(j.cron)"
        cfg.secondaryText = "\(j.actionTitle)\(j.needsPkg && !j.pkg.isEmpty ? " · \(j.pkg)" : "") · \(plan)\n下次 \(ScheduleStore.shortTime(j.nextRun)) · \(j.lastResult.isEmpty ? "尚未执行" : j.lastResult)"
        cfg.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        guard let id = jobs[safe: indexPath.row]?.id else { return }
        let sheet = UIAlertController(title: "任务操作", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "立即执行", style: .default) { [weak self] _ in
            guard let self else { return }
            self.store.runNow(id: id) { [weak self] result in
                guard let self else { return }
                UIKitHelper.alert("执行结果", result, in: self)
            }
        })
        let job = jobs[indexPath.row]
        sheet.addAction(UIAlertAction(title: job.paused ? "恢复" : "暂停", style: .default) { [weak self] _ in
            self?.store.togglePause(id: id)
            self?.reload()
        })
        sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            self?.store.remove(id: id)
            self?.reload()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tv
        sheet.popoverPresentationController?.sourceRect = tv.rectForRow(at: indexPath)
        present(sheet, animated: true)
    }

    func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, let id = jobs[safe: indexPath.row]?.id else { return }
        store.remove(id: id)
        reload()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}

/// 任务编辑表单（Modal 提供「取消」按钮 + 下拉手势关闭）
final class ScheduleEditorViewController: UIViewController {

    private let host: AdbHost
    private let action: String
    private let onSave: (ScheduleJob) -> Void
    private var job = ScheduleJob()

    private let nameField = ScheduleEditorViewController.makeField("任务名（可留空）")
    private let pkgField = ScheduleEditorViewController.makeField("包名（卸载/清数据/强停必填）")
    private let intervalField = ScheduleEditorViewController.makeField("间隔秒数（如 3600）")
    private let cronField = ScheduleEditorViewController.makeField("Cron：分 时 日 月 周")
    private let modeControl: UISegmentedControl = {
        let s = UISegmentedControl(items: ["固定间隔", "Cron 表达式"])
        s.selectedSegmentIndex = 0
        return s
    }()
    private let form = UIStackView()

    init(host: AdbHost, action: String, onSave: @escaping (ScheduleJob) -> Void) {
        self.host = host; self.action = action; self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeField(_ placeholder: String) -> UITextField {
        let tf = UITextField()
        tf.placeholder = placeholder
        tf.borderStyle = .roundedRect
        tf.font = .systemFont(ofSize: 15)
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        return tf
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "新建定时任务"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))

        job.action = action
        nameField.text = action
        intervalField.text = "3600"
        intervalField.keyboardType = .numberPad
        cronField.text = "0 3 * * *"
        if !job.needsPkg { pkgField.isHidden = true }

        form.axis = .vertical; form.spacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false
        let tip = UILabel(); tip.text = "动作：\(ScheduleJob.actions.first { $0.0 == action }?.1 ?? action)\n目标：\(host.serial)"
        tip.font = .systemFont(ofSize: 13); tip.textColor = .secondaryLabel; tip.numberOfLines = 0
        form.addArrangedSubview(tip)
        form.addArrangedSubview(nameField)
        if job.needsPkg { form.addArrangedSubview(pkgField) }
        form.addArrangedSubview(modeControl)
        form.addArrangedSubview(intervalField)
        form.addArrangedSubview(cronField)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeChanged()

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(form)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            form.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            form.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),
            form.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])
    }

    @objc private func modeChanged() {
        let isCron = modeControl.selectedSegmentIndex == 1
        intervalField.isHidden = isCron
        cronField.isHidden = !isCron
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func save() {
        job.name = nameField.text?.trimmed ?? ""
        job.pkg = pkgField.text?.trimmed ?? ""
        job.hostIP = host.ip
        job.hostPort = host.port
        if modeControl.selectedSegmentIndex == 1 {
            job.mode = "cron"
            job.cron = cronField.text?.trimmed ?? "0 3 * * *"
            guard ScheduleStore.validateCron(job.cron) else {
                UIKitHelper.alert("Cron 格式错误", "请输入 5 段：分 时 日 月 周，例如 0 3 * * *", in: self); return
            }
        } else {
            job.mode = "interval"
            job.intervalSec = Int(intervalField.text?.trimmed ?? "") ?? 0
            guard job.intervalSec >= 60 else {
                UIKitHelper.alert("间隔太短", "最小间隔为 60 秒", in: self); return
            }
        }
        onSave(job)
        dismiss(animated: true)
    }
}

extension ScheduleStore {
    static func validateCron(_ expr: String) -> Bool {
        let fields = expr.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " })
        return fields.count == 5
    }
}

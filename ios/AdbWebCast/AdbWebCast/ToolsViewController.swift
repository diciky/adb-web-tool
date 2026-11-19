import UIKit

/// 工具箱页：截图 / 电源 / 遥控按键 / 文本输入 / Shell 命令 / 剪贴板
final class ToolsViewController: UIViewController {

    private let host: AdbHost
    private var picker = DocumentPickerHelper()

    // MARK: UI
    private let screenshotBtn = ToolsViewController.btn("截取屏幕", "camera")
    private let powerBtn = ToolsViewController.btn("电源操作", "power")
    private let remoteLabel: UILabel = {
        let l = UILabel(); l.text = "遥控按键"; l.font = .boldSystemFont(ofSize: 15); return l
    }()
    private let shellInput: UITextField = {
        let t = UITextField(); t.placeholder = "输入 shell 命令，回车执行"
        t.borderStyle = .roundedRect; t.font = .systemFont(ofSize: 14)
        t.autocorrectionType = .no; t.autocapitalizationType = .none; return t
    }()
    private let shellOutput: UITextView = {
        let t = UITextView(); t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        t.isEditable = false; t.backgroundColor = .secondarySystemBackground
        t.layer.cornerRadius = 8; t.translatesAutoresizingMaskIntoConstraints = false; return t
    }()
    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = ""; return l
    }()

    private static func btn(_ title: String, _ icon: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle("  \(title)", for: .normal)
        b.setImage(UIImage(systemName: icon), for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 14)
        b.backgroundColor = .secondarySystemFill
        b.layer.cornerRadius = 9
        b.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return b
    }

    // 遥控按键网格：标题 -> keyevent
    private let keys: [(String, Int)] = [
        ("↑", 19), ("↓", 20), ("←", 21), ("→", 22),
        ("OK", 23), ("返回", 4), ("主页", 3), ("菜单", 82),
        ("音量+", 24), ("音量-", 25), ("静音", 164), ("电源", 26),
    ]

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "工具箱"
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])

        stack.addArrangedSubview(screenshotBtn)
        stack.addArrangedSubview(powerBtn)

        stack.addArrangedSubview(remoteLabel)
        let grid = UIStackView(); grid.axis = .horizontal; grid.distribution = .fillEqually
        grid.spacing = 8
        let leftCol = UIStackView(); leftCol.axis = .vertical; leftCol.spacing = 8
        let rightCol = UIStackView(); rightCol.axis = .vertical; rightCol.spacing = 8
        for (i, k) in keys.enumerated() {
            let b = UIButton(type: .system); b.setTitle(k.0, for: .normal)
            b.titleLabel?.font = .boldSystemFont(ofSize: 15); b.backgroundColor = .secondarySystemFill
            b.layer.cornerRadius = 8; b.heightAnchor.constraint(equalToConstant: 40).isActive = true
            b.tag = k.1; b.addTarget(self, action: #selector(keyTap(_:)), for: .touchUpInside)
            (i % 2 == 0 ? leftCol : rightCol).addArrangedSubview(b)
        }
        grid.addArrangedSubview(leftCol); grid.addArrangedSubview(rightCol)
        stack.addArrangedSubview(grid)

        let textBtn = ToolsViewController.btn("输入文字到电视", "keyboard")
        textBtn.addTarget(self, action: #selector(inputText), for: .touchUpInside)
        stack.addArrangedSubview(textBtn)

        let clipBtn = ToolsViewController.btn("设置剪贴板（中文）", "doc.on.clipboard")
        clipBtn.addTarget(self, action: #selector(clipboard), for: .touchUpInside)
        stack.addArrangedSubview(clipBtn)

        stack.addArrangedSubview(shellInput)
        let shellBtn = ToolsViewController.btn("执行 Shell 命令", "terminal")
        shellBtn.addTarget(self, action: #selector(runShell), for: .touchUpInside)
        stack.addArrangedSubview(shellBtn)
        stack.addArrangedSubview(shellOutput)

        stack.addArrangedSubview(statusLabel)

        screenshotBtn.addTarget(self, action: #selector(screenshot), for: .touchUpInside)
        powerBtn.addTarget(self, action: #selector(power), for: .touchUpInside)
        shellInput.addTarget(self, action: #selector(runShell), for: .editingDidEndOnExit)
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.statusLabel.text = s } }

    // MARK: 截图
    @objc private func screenshot() {
        status("截图中…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                let png = try client.screenshot()
                client.disconnect()
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot_\(Int(Date().timeIntervalSince1970)).png")
                try png.write(to: tmp)
                DispatchQueue.main.async {
                    self.status("截图成功（\(png.count) 字节）")
                    let vc = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
                    vc.popoverPresentationController?.sourceView = self.screenshotBtn
                    self.present(vc, animated: true)
                }
            } catch {
                client.disconnect()
                self.status("截图失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 电源
    @objc private func power() {
        let sheet = UIAlertController(title: "电源操作", message: nil, preferredStyle: .actionSheet)
        [("重启", "reboot"), ("关机", "reboot -p"), ("重启到 Recovery", "reboot recovery"),
         ("休眠（息屏）", "input keyevent 223"), ("唤醒（亮屏）", "input keyevent 224")].forEach { item in
            sheet.addAction(UIAlertAction(title: item.0, style: .default) { _ in self.execCmd(item.1, msg: "已发送：\(item.0)") })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        sheet.popoverPresentationController?.sourceView = powerBtn
        present(sheet, animated: true)
    }

    @objc private func keyTap(_ sender: UIButton) { execCmd("input keyevent \(sender.tag)", msg: "按键已发送") }

    @objc private func inputText() {
        UIKitHelper.input("输入文字", placeholder: "英文字母/数字", in: self) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let escaped = text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "%s")
            self.execCmd("input text '\(escaped)'", msg: "文本已输入（中文请用剪贴板）")
        }
    }

    @objc private func clipboard() {
        UIKitHelper.input("设置电视剪贴板", placeholder: "可输入中文", in: self) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
            // 优先 Clipper 广播，失败回退 service call
            let cmd = "am broadcast -a org.albireo.clipper.set -e text \"\(escaped)\""
            self.execCmd(cmd, msg: "已尝试写入剪贴板（需电视安装 Clipper 应用支持中文）")
        }
    }

    @objc private func runShell() {
        guard let cmd = shellInput.text?.trimmed, !cmd.isEmpty else { return }
        status("执行中…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var out = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                out = try client.shell(cmd, timeout: 60); client.disconnect()
            } catch { out = "错误：\(error.localizedDescription)"; client.disconnect() }
            DispatchQueue.main.async {
                self.shellOutput.text = out.isEmpty ? "（无输出）" : out
                self.status("命令执行完毕")
            }
        }
    }

    private func execCmd(_ cmd: String, msg: String) {
        status("发送中…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient(); var err = ""
            do { try client.connect(host: self.host.ip, port: self.host.port); _ = try client.shell(cmd, timeout: 30); client.disconnect() }
            catch { err = error.localizedDescription; client.disconnect() }
            self.status(err.isEmpty ? msg : "失败：\(err)")
        }
    }
}

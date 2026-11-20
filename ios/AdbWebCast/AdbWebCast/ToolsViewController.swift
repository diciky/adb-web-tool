import UIKit

/// Shell 命令页：直接执行任意 shell 命令并显示输出。
/// 屏幕/电源/文字输入/剪贴板已平铺到「设备」页宫格，不再经此折叠页。
final class ShellViewController: UIViewController {

    private let host: AdbHost

    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = ""; return l
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

    private static func btn(_ title: String, _ icon: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle("  \(title)", for: .normal)
        b.setImage(UIImage(systemName: icon), for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 14)
        b.backgroundColor = .secondarySystemFill
        b.layer.cornerRadius = 9
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Shell 命令"
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

        stack.addArrangedSubview(shellInput)
        let shellBtn = ShellViewController.btn("执行 Shell 命令", "terminal")
        shellBtn.addTarget(self, action: #selector(runShell), for: .touchUpInside)
        stack.addArrangedSubview(shellBtn)
        shellOutput.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(shellOutput)
        stack.addArrangedSubview(statusLabel)

        shellInput.addTarget(self, action: #selector(runShell), for: .editingDidEndOnExit)
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.statusLabel.text = s } }

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

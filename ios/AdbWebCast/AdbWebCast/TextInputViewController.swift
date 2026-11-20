import UIKit

/// 合并「文字输入」与「剪贴板」：一个输入框同时支持英文直输与中文剪贴板写入。
///
/// 策略：
/// 1. 电视安装 Clipper → 广播写入剪贴板（可选自动粘贴）；
/// 2. 老固件 → `service call clipboard`；
/// 3. 纯 ASCII → `input text` 兜底；
/// 4. 中文且无剪贴板能力 → 明确报错，不再静默失败。
final class TextInputViewController: UIViewController {

    private let host: AdbHost
    private let defaultsKey = "adbweb.text.history.v1"
    private let clipperPackages = ["org.albireo.clipper"]

    private enum Mode: Int, CaseIterable {
        case smart = 0
        case clipboard = 1
        case direct = 2

        var title: String {
            switch self {
            case .smart: return "智能"
            case .clipboard: return "剪贴板"
            case .direct: return "直输"
            }
        }
    }

    private lazy var modeControl: UISegmentedControl = {
        let c = UISegmentedControl(items: Mode.allCases.map { $0.title })
        c.selectedSegmentIndex = Mode.smart.rawValue
        c.accessibilityLabel = "输入方式"
        c.accessibilityHint = "智能会自动选择中文剪贴板或英文直输"
        return c
    }()

    private let hintLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .footnote)
        l.adjustsFontForContentSizeCategory = true
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.text = "可输入中文、英文或标点。智能模式会优先写入电视剪贴板并粘贴；纯英文也可直接输入。"
        return l
    }()

    private lazy var textView: UITextView = {
        let t = UITextView()
        t.font = .preferredFont(forTextStyle: .body)
        t.adjustsFontForContentSizeCategory = true
        t.layer.cornerRadius = 10
        t.layer.borderWidth = 1
        t.layer.borderColor = UIColor.separator.cgColor
        t.backgroundColor = .secondarySystemBackground
        t.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        t.accessibilityLabel = "要发送到电视的文字"
        t.translatesAutoresizingMaskIntoConstraints = false
        t.heightAnchor.constraint(equalToConstant: 120).isActive = true
        return t
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .footnote)
        l.adjustsFontForContentSizeCategory = true
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.text = ""
        return l
    }()

    private let historyStack: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.spacing = 8
        s.distribution = .equalSpacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private var history: [String] = []

    init(host: AdbHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "文字输入 / 剪贴板"
        view.backgroundColor = .systemBackground
        history = (UserDefaults.standard.array(forKey: defaultsKey) as? [String]) ?? []

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])

        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(modeControl)
        stack.addArrangedSubview(textView)

        let pasteRow = UIStackView()
        pasteRow.axis = .horizontal
        pasteRow.spacing = 8
        pasteRow.distribution = .fillEqually
        let pasteButton = makeButton("粘贴手机文本", "doc.on.clipboard")
        pasteButton.addTarget(self, action: #selector(pasteFromPhone), for: .touchUpInside)
        pasteButton.accessibilityLabel = "从手机剪贴板粘贴文字"
        let copyButton = makeButton("复制到手机", "doc.on.doc")
        copyButton.addTarget(self, action: #selector(copyToPhone), for: .touchUpInside)
        copyButton.accessibilityLabel = "复制文字到手机剪贴板"
        pasteRow.addArrangedSubview(pasteButton)
        pasteRow.addArrangedSubview(copyButton)
        stack.addArrangedSubview(pasteRow)

        let sendButton = makeButton("发送到电视", "paperplane.fill")
        sendButton.backgroundColor = .systemBlue
        sendButton.tintColor = .white
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        sendButton.accessibilityLabel = "发送文字到电视"
        stack.addArrangedSubview(sendButton)

        let historyTitle = UILabel()
        historyTitle.font = .preferredFont(forTextStyle: .caption1)
        historyTitle.textColor = .secondaryLabel
        historyTitle.text = "最近使用（点按填入）"
        stack.addArrangedSubview(historyTitle)
        stack.addArrangedSubview(historyStack)
        renderHistory()
        stack.addArrangedSubview(statusLabel)
    }

    private func makeButton(_ title: String, _ symbol: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle("  \(title)", for: .normal)
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        b.backgroundColor = .secondarySystemFill
        b.layer.cornerRadius = 9
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { self.statusLabel.text = text }
    }

    @objc private func pasteFromPhone() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            status("手机剪贴板为空")
            return
        }
        textView.text = text
        status("已从手机剪贴板粘贴")
    }

    @objc private func copyToPhone() {
        guard !textView.text.isEmpty else { return }
        UIPasteboard.general.string = textView.text
        status("已复制到手机剪贴板")
    }

    private func renderHistory() {
        historyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for text in history.prefix(4) {
            let b = UIButton(type: .system)
            var config = UIButton.Configuration.plain()
            config.title = text.count > 12 ? String(text.prefix(12)) + "…" : text
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            b.configuration = config
            b.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            b.layer.cornerRadius = 8
            b.backgroundColor = .tertiarySystemFill
            b.accessibilityLabel = "填入历史文字：\(text)"
            b.addTarget(self, action: #selector(fillHistory(_:)), for: .touchUpInside)
            historyStack.addArrangedSubview(b)
        }
    }

    @objc private func fillHistory(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        let trimmed = title.replacingOccurrences(of: "…", with: "")
        if let match = history.first(where: { $0.hasPrefix(trimmed) }) { textView.text = match }
    }

    @objc private func send() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status("请先输入文字"); return }
        let mode = Mode(rawValue: modeControl.selectedSegmentIndex) ?? .smart
        status("正在发送到电视…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var message = ""
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                message = try self.deliver(text, mode: mode, client: client)
                client.disconnect()
                DispatchQueue.main.async {
                    self.saveHistory(text)
                    self.status(message)
                }
            } catch {
                client.disconnect()
                let msg = "失败：\(error.localizedDescription)"
                DispatchQueue.main.async { self.status(msg) }
            }
        }
    }

    /// 返回用户可读的结果描述；抛出时用 AdbError.commandFailed 表达能力缺失。
    private func deliver(_ text: String, mode: Mode, client: AdbClient) throws -> String {
        let isASCII = text.unicodeScalars.allSatisfy { $0.value < 128 }

        if mode == .direct {
            guard isASCII else {
                throw AdbError.commandFailed("直输模式只支持英文/数字/半角标点，中文请切换到智能或剪贴板模式")
            }
            _ = try client.shell("input text \(Self.shellSingleQuote(text.replacingOccurrences(of: " ", with: "%s")))", timeout: 30)
            return "已直接输入：\(text)"
        }

        let installed = (try? client.shell("pm list packages", timeout: 30)) ?? ""
        let helper = clipperPackages.first { installed.contains($0) }

        if let helper {
            let cmd = "am broadcast -a \(helper).set -e text \(Self.shellDoubleQuote(text))"
            _ = try client.shell(cmd, timeout: 30)
            _ = try? client.shell("input keyevent 279", timeout: 15)  // KEYCODE_PASTE
            return "已通过剪贴板写入并粘贴：\(text)"
        }

        // Android ≤ 6 的系统剪贴板服务；失败再按模式决定是否直输 ASCII。
        let serviceCmd = "service call clipboard 2 i32 1 s16 \(Self.shellDoubleQuote(text))"
        if (try? client.shell(serviceCmd, timeout: 20)) != nil {
            _ = try? client.shell("input keyevent 279", timeout: 15)
            return "已通过系统剪贴板写入并粘贴：\(text)"
        }

        if isASCII && mode != .clipboard {
            _ = try client.shell("input text \(Self.shellSingleQuote(text.replacingOccurrences(of: " ", with: "%s")))", timeout: 30)
            return "剪贴板不可用，已直输英文：\(text)"
        }

        throw AdbError.commandFailed("电视未提供剪贴板写入能力。请在电视安装 Clipper 应用后重试（中文必须走剪贴板）。")
    }

    private func saveHistory(_ text: String) {
        var items = history.filter { $0 != text }
        items.insert(text, at: 0)
        history = Array(items.prefix(8))
        UserDefaults.standard.set(history, forKey: defaultsKey)
        DispatchQueue.main.async { self.renderHistory() }
    }

    // MARK: - Shell  quoting

    /// 双引号包裹：转义反斜杠、双引号、美元符与反引号，避免 shell 注入。
    private static func shellDoubleQuote(_ raw: String) -> String {
        let oneLine = raw.replacingOccurrences(of: "\r", with: " ")
                         .replacingOccurrences(of: "\n", with: " ")
        let escaped = oneLine.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
                             .replacingOccurrences(of: "$", with: "\\$")
                             .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    /// 单引号包裹：内部单引号写成 `'\''`，其余字符原样保留。
    private static func shellSingleQuote(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

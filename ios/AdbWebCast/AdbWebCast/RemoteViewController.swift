import UIKit

/// 独立遥控页：实体电视遥控器风格布局，方向键/音量键长按连发。
/// 使用一条长连接串行发送 keyevent，避免每次按键重新握手。
final class RemoteViewController: UIViewController {

    private let host: AdbHost
    private let deviceModel: String

    private let cmdQueue = DispatchQueue(label: "remote.cmd.\(UUID().uuidString)", qos: .userInitiated)
    private var client: AdbClient?
    private var repeatTimer: Timer?
    private var repeatKey: Int = -1

    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.textAlignment = .center; l.numberOfLines = 0; l.text = "正在连接电视…"; return l
    }()

    /// 需要长按连发的按键（方向键/音量/快进快退）
    private let repeatable: Set<Int> = [19, 20, 21, 22, 24, 25, 89, 90]

    init(host: AdbHost, deviceModel: String) {
        self.host = host; self.deviceModel = deviceModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "遥控器"
        view.backgroundColor = .systemBackground
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onStage(_:)), name: .adbConnectionStage, object: nil)
        cmdQueue.async { [weak self] in self?.ensureClient() }
    }

    @objc private func onStage(_ note: Notification) {
        guard let text = note.object as? String else { return }
        DispatchQueue.main.async { [weak self] in self?.statusLabel.text = text }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRepeat()
        NotificationCenter.default.removeObserver(self, name: .adbConnectionStage, object: nil)
        cmdQueue.async { [weak self] in self?.client?.disconnect(); self?.client = nil }
    }

    // MARK: 布局
    private func buildUI() {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let outer = UIStackView(); outer.axis = .vertical; outer.spacing = 16
        outer.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16),
            outer.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            outer.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            outer.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 20),
            outer.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -40),
        ])

        outer.addArrangedSubview(statusLabel)

        // 顶部功能键
        let topRow = row([keyBtn("电源", 26, .systemRed, repeat: false),
                          keyBtn("主页", 3, .systemGray, repeat: false),
                          keyBtn("返回", 4, .systemGray, repeat: false),
                          keyBtn("菜单", 82, .systemGray, repeat: false)])
        outer.addArrangedSubview(topRow)

        // 十字方向键（九宫格）
        let pad = UIStackView(); pad.axis = .vertical; pad.spacing = 10
        pad.distribution = .fillEqually
        let r1 = row([keyBtn("", -1, .clear, enabled: false), keyBtn("▲", 19, .systemBlue), keyBtn("", -1, .clear, enabled: false)])
        let r2 = row([keyBtn("◀", 21, .systemBlue), keyBtn("OK", 23, .systemBlue, repeat: false), keyBtn("▶", 22, .systemBlue)])
        let r3 = row([keyBtn("", -1, .clear, enabled: false), keyBtn("▼", 20, .systemBlue), keyBtn("", -1, .clear, enabled: false)])
        [r1, r2, r3].forEach { pad.addArrangedSubview($0) }
        pad.heightAnchor.constraint(equalToConstant: 260).isActive = true
        outer.addArrangedSubview(pad)

        // 音量键
        let volRow = row([keyBtn("音量 −", 25, .systemGray),
                          keyBtn("静音", 164, .systemGray, repeat: false),
                          keyBtn("音量 +", 24, .systemGray)])
        outer.addArrangedSubview(volRow)

        // 播放键
        let playRow = row([keyBtn("⏮ 快退", 89, .systemGray),
                           keyBtn("⏯ 播放", 85, .systemGray, repeat: false),
                           keyBtn("⏭ 快进", 90, .systemGray)])
        outer.addArrangedSubview(playRow)

        // 数字键 0-9
        var digitRows: [UIStackView] = []
        var current: [UIButton] = []
        // Android KEYCODE_1=8 … KEYCODE_9=16，KEYCODE_0=7
        for n in 1...9 {
            current.append(keyBtn("\(n)", n + 7, .systemGray, repeat: false))
            if current.count == 3 { digitRows.append(row(current)); current = [] }
        }
        current.append(keyBtn("静", 164, .systemGray, repeat: false))
        current.append(keyBtn("0", 7, .systemGray, repeat: false))
        current.append(keyBtn("⌫", 67, .systemGray, repeat: false))
        digitRows.append(row(current))
        digitRows.forEach { outer.addArrangedSubview($0) }
    }

    private func row(_ buttons: [UIButton]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: buttons)
        s.axis = .horizontal; s.spacing = 10; s.distribution = .fillEqually
        s.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return s
    }

    private func keyBtn(_ title: String, _ keycode: Int, _ color: UIColor,
                        repeat: Bool = true, enabled: Bool = true) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 18)
        b.backgroundColor = color
        b.setTitleColor(color == .clear ? .clear : .white, for: .normal)
        b.isEnabled = enabled
        b.layer.cornerRadius = 12
        b.tag = keycode
        b.isUserInteractionEnabled = enabled
        if enabled {
            b.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
            b.addTarget(self, action: #selector(keyUp), for: .touchUpInside)
            b.addTarget(self, action: #selector(keyUp), for: .touchUpOutside)
            b.addTarget(self, action: #selector(keyUp), for: .touchCancel)
        }
        return b
    }

    // MARK: 按键发送
    @objc private func keyDown(_ sender: UIButton) {
        let code = sender.tag
        guard code > 0 else { return }
        sendKey(code)
        let canRepeat = repeatable.contains(code)
        stopRepeat()
        repeatKey = code
        if canRepeat {
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
                self?.beginRepeat()
            }
        }
    }

    private func beginRepeat() {
        guard repeatKey > 0 else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.repeatKey > 0 else { return }
            self.sendKey(self.repeatKey)
        }
    }

    @objc private func keyUp() { stopRepeat() }
    private func stopRepeat() { repeatTimer?.invalidate(); repeatTimer = nil; repeatKey = -1 }

    private func ensureClient() {
        if client != nil { return }
        let c = AdbClient()
        do {
            try c.connect(host: host.ip, port: host.port)
            client = c
            let info = c.readDeviceInfo()
            if !info.model.isEmpty { DeviceStore.remember(ip: host.ip, port: host.port, name: info.model) }
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "✅ 已连接 \(info.model.isEmpty ? self?.host.serial ?? "" : info.model)\n长按方向键/音量键可连发"
            }
        } catch {
            c.disconnect()
            DispatchQueue.main.async { [weak self] in
                self?.statusLabel.text = "⚠️ 连接失败：\(error.localizedDescription)\n请确认电视已授权 ADB"
            }
        }
    }

    private func sendKey(_ code: Int) {
        cmdQueue.async { [weak self] in
            guard let self else { return }
            self.ensureClient()
            guard let c = self.client else { return }
            _ = try? c.shell("input keyevent \(code)", timeout: 6)
        }
    }
}

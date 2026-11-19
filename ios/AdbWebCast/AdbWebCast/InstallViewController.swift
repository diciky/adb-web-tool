import UIKit
import UniformTypeIdentifiers

/// 设备详情页：选择 APK 并安装，显示推送/安装进度。全程原生，不依赖任何 Web 服务。
final class InstallViewController: UIViewController {

    private let host: AdbHost
    private let deviceModel: String
    private var apkURL: URL?
    private var installing = false
    private var pendingPanel: (([URL]?) -> Void)?

    private let deviceLabel: UILabel = {
        let l = UILabel()
        l.font = .boldSystemFont(ofSize: 17)
        l.numberOfLines = 0
        return l
    }()
    private let hintLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.text = "首次连接请在电视上勾选「一律允许 / 始终允许」后再点安装。"
        return l
    }()
    private let fileLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        l.text = "尚未选择 APK"
        return l
    }()
    private let pickButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("选择 APK 文件", for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 15)
        b.backgroundColor = UIColor.secondarySystemFill
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }()
    private let installButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("安装到电视", for: .normal)
        b.titleLabel?.font = .boldSystemFont(ofSize: 16)
        b.backgroundColor = UIColor.systemBlue
        b.setTitleColor(.white, for: .normal)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 48).isActive = true
        return b
    }()
    private let progressView: UIProgressView = {
        let p = UIProgressView(progressViewStyle: .bar)
        p.progress = 0
        return p
    }()
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }()

    init(host: AdbHost, deviceModel: String) {
        self.host = host
        self.deviceModel = deviceModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "安装 APK"
        view.backgroundColor = .systemBackground
        deviceLabel.text = deviceModel.isEmpty ? host.serial : "\(deviceModel)\n\(host.serial)"
        buildUI()
    }

    private func buildUI() {
        let stack = UIStackView(arrangedSubviews: [
            deviceLabel, hintLabel, pickButton, fileLabel,
            progressView, statusLabel, installButton,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        pickButton.addTarget(self, action: #selector(pickAPK), for: .touchUpInside)
        installButton.addTarget(self, action: #selector(install), for: .touchUpInside)
    }

    @objc private func pickAPK() {
        // 放行通用 UTI：iOS 不认识 apk 的 UTI，限制类型会导致文件灰色不可选。
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item, .data, .archive, .package], asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    @objc private func install() {
        guard !installing else { return }
        guard let url = apkURL else {
            alert("未选择文件", "请先选择一个 APK 安装包")
            return
        }
        installing = true
        installButton.isEnabled = false
        installButton.setTitle("安装中…", for: .normal)
        progressView.progress = 0
        statusLabel.text = "正在连接 \(host.serial) …"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                DispatchQueue.main.async { self.statusLabel.text = "正在推送 APK 到电视…" }
                let output = try client.installAPK(localURL: url) { pct in
                    DispatchQueue.main.async {
                        self.progressView.progress = Float(pct) / 100.0
                        if pct >= 99 { self.statusLabel.text = "正在安装，请稍候…" }
                    }
                }
                client.disconnect()
                let success = output.localizedCaseInsensitiveContains("Success")
                DispatchQueue.main.async {
                    self.finish(success: success, message: output.trimmed)
                }
            } catch {
                client.disconnect()
                DispatchQueue.main.async {
                    self.finish(success: false, message: error.localizedDescription)
                }
            }
        }
    }

    private func finish(success: Bool, message: String) {
        installing = false
        installButton.isEnabled = true
        installButton.setTitle("安装到电视", for: .normal)
        let title = success ? "安装成功 ✅" : "安装失败"
        let msg = success ? "已在 \(deviceModel.isEmpty ? host.serial : deviceModel) 上完成安装。" : message
        let c = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        c.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            if success { self?.navigationController?.popViewController(animated: true) }
        })
        present(c, animated: true)
    }

    private func alert(_ title: String, _ msg: String) {
        let c = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        c.addAction(UIAlertAction(title: "好", style: .default))
        present(c, animated: true)
    }
}

// MARK: - UIDocumentPickerDelegate
extension InstallViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        apkURL = url
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let mb = Double(size) / 1024 / 1024
        fileLabel.text = "已选择：\(url.lastPathComponent)  (\(String(format: "%.1f", mb)) MB)"
        installButton.isEnabled = true
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPanel = nil
    }
}

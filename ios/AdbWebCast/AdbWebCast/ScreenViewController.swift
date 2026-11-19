import UIKit

/// 屏幕页：截图直接在 App 内预览；「实时屏幕」循环 screencap 定时刷新，近似实时查看电视画面。
final class ScreenViewController: UIViewController {

    private let host: AdbHost
    private var live = false
    private var liveClient: AdbClient?
    private let workQueue = DispatchQueue(label: "screen.live.\(UUID().uuidString)", qos: .userInitiated)

    private let imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.backgroundColor = .black
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()
    private let placeholder: UILabel = {
        let l = UILabel(); l.text = "点击下方「截取屏幕」或开启「实时屏幕」\n画面会显示在这里"
        l.textColor = .tertiaryLabel; l.textAlignment = .center; l.numberOfLines = 0
        l.font = .systemFont(ofSize: 15); return l
    }()
    private let statusLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 12); l.textColor = .secondaryLabel
        l.textAlignment = .center; l.numberOfLines = 0; return l
    }()
    private let shotBtn: UIButton = ScreenViewController.btn("截取屏幕", "camera")
    private let liveBtn: UIButton = ScreenViewController.btn("开启实时屏幕", "dot.radiowaves.left.and.right")
    private let saveBtn: UIButton = ScreenViewController.btn("保存到相册", "square.and.arrow.down")

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

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "屏幕"
        view.backgroundColor = .systemBackground
        setupUI()
        shotBtn.addTarget(self, action: #selector(takeScreenshot), for: .touchUpInside)
        liveBtn.addTarget(self, action: #selector(toggleLive), for: .touchUpInside)
        saveBtn.addTarget(self, action: #selector(saveToPhotos), for: .touchUpInside)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        live = false
        workQueue.async { [weak self] in self?.liveClient?.disconnect(); self?.liveClient = nil }
    }

    private func setupUI() {
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 0.58),
        ])
        imageView.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -20),
        ])
        let btns = UIStackView(arrangedSubviews: [shotBtn, liveBtn, saveBtn, statusLabel])
        btns.axis = .vertical; btns.spacing = 12; btns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(btns)
        NSLayoutConstraint.activate([
            btns.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            btns.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            btns.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.statusLabel.text = s } }
    private func show(_ image: UIImage) {
        DispatchQueue.main.async {
            self.imageView.image = image
            self.placeholder.isHidden = true
        }
    }

    // MARK: 单张截图
    @objc private func takeScreenshot() {
        status("截图中…")
        workQueue.async { [weak self] in
            guard let self else { return }
            let c = AdbClient()
            do {
                try c.connect(host: self.host.ip, port: self.host.port)
                let png = try c.screenshot()
                c.disconnect()
                guard let img = UIImage(data: png) else { throw AdbError.protocolError("截图数据无效") }
                self.show(img)
                self.status("截图成功 · \(png.count) 字节 · 可点「保存到相册」")
            } catch {
                c.disconnect()
                self.status("截图失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 实时屏幕
    @objc private func toggleLive() {
        live.toggle()
        if live {
            liveBtn.setTitle("  关闭实时屏幕", for: .normal)
            liveBtn.backgroundColor = .systemRed
            status("实时屏幕开启中…（每 ~0.7s 抓一帧）")
            workQueue.async { [weak self] in self?.liveLoop() }
        } else {
            liveBtn.setTitle("  开启实时屏幕", for: .normal)
            liveBtn.backgroundColor = .secondarySystemFill
            status("已停止实时屏幕")
        }
    }

    private func liveLoop() {
        let c = AdbClient()
        do {
            try c.connect(host: host.ip, port: host.port)
            self.liveClient = c
        } catch {
            c.disconnect()
            status("实时屏幕连接失败：\(error.localizedDescription)")
            DispatchQueue.main.async { [weak self] in
                self?.live = false
                self?.liveBtn.setTitle("  开启实时屏幕", for: .normal)
                self?.liveBtn.backgroundColor = .secondarySystemFill
            }
            return
        }
        var frames = 0
        let start = Date()
        while live {
            do {
                let png = try c.screenshot()
                if let img = UIImage(data: png) { self.show(img) }
                frames += 1
                let fps = Double(frames) / max(0.1, Date().timeIntervalSince(start))
                status(String(format: "实时屏幕 · 约 %.1f 帧/秒 · 抓帧 %.0f KB", fps, Double(png.count)/1024))
            } catch {
                status("抓帧中断：\(error.localizedDescription)")
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        c.disconnect()
        self.liveClient = nil
    }

    // MARK: 保存到相册
    @objc private func saveToPhotos() {
        guard let img = imageView.image else {
            status("还没有画面，请先截图")
            return
        }
        UIImageWriteToSavedPhotosAlbum(img, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if let e = error { status("保存失败：\(e.localizedDescription)") }
        else { status("✅ 已保存到相册") }
    }
}

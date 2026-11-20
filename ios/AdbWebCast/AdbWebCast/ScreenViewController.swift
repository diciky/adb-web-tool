import UIKit
import Vision

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Pro 工具", style: .plain, target: self, action: #selector(proTools)
        )
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
                if PurchaseManager.shared.isPro { ScreenshotHistory.save(img, host: self.host) }
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
        var consecutiveFails = 0
        let start = Date()
        while live {
            do {
                let png = try c.screenshot()
                if let img = UIImage(data: png) { self.show(img) }
                frames += 1
                consecutiveFails = 0
                let fps = Double(frames) / max(0.1, Date().timeIntervalSince(start))
                status(String(format: "实时屏幕 · 约 %.1f 帧/秒 · 抓帧 %.0f KB", fps, Double(png.count)/1024))
            } catch {
                // 抓帧失败（如电视进入 DRM 内容）：退避重试，连续失败自动熔断，
                // 绝不 0.15s 高频重试打爆电视 adbd（v3.0.1 日志实证的卡死根因）。
                consecutiveFails += 1
                status("抓帧失败（\(consecutiveFails)/5）：\(error.localizedDescription)")
                if consecutiveFails >= 5 {
                    status("连续抓帧失败，已自动停止实时屏幕。切回电视桌面后可重新开启")
                    break
                }
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        c.disconnect()
        self.liveClient = nil
        // 熔断退出时同步恢复开关状态与按钮外观
        DispatchQueue.main.async { [weak self] in
            guard let self, self.live else { return }
            self.live = false
            self.liveBtn.setTitle("  开启实时屏幕", for: .normal)
            self.liveBtn.backgroundColor = .secondarySystemFill
        }
    }

    // MARK: Pro 工具（历史 / OCR / 标注）
    @objc private func proTools() {
        ProGate.run(from: self) { [weak self] in
            guard let self else { return }
            let sheet = UIAlertController(title: "Pro 截屏工具", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "截图历史", style: .default) { [weak self] _ in
                self?.openHistory()
            })
            sheet.addAction(UIAlertAction(title: "OCR 识别画面文字", style: .default) { [weak self] _ in
                self?.ocrCurrent()
            })
            sheet.addAction(UIAlertAction(title: "标注当前截图", style: .default) { [weak self] _ in
                self?.annotateCurrent()
            })
            sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
            sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
            self.present(sheet, animated: true)
        }
    }

    private func openHistory() {
        navigationController?.pushViewController(ScreenshotHistoryViewController(), animated: true)
    }

    private func ocrCurrent() {
        guard let cgImage = imageView.image?.cgImage else {
            status("请先截图，再使用 OCR")
            return
        }
        status("正在识别文字…")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = ""
            var failure = ""
            do {
                try handler.perform([request])
                result = (request.results ?? []).compactMap { $0.topCandidate(1)?.string }.joined(separator: "\n")
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if !result.isEmpty {
                    self.status("OCR 识别完成")
                    let ac = UIAlertController(title: "识别结果", message: result, preferredStyle: .alert)
                    ac.addAction(UIAlertAction(title: "复制", style: .default) { _ in
                        UIPasteboard.general.string = result
                    })
                    ac.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
                        let av = UIActivityViewController(activityItems: [result], applicationActivities: nil)
                        self?.present(av, animated: true)
                    })
                    ac.addAction(UIAlertAction(title: "关闭", style: .cancel))
                    self.present(ac, animated: true)
                } else {
                    self.status(failure.isEmpty ? "没有识别到文字" : "OCR 失败：\(failure)")
                }
            }
        }
    }

    private func annotateCurrent() {
        guard let image = imageView.image else {
            status("请先截图，再标注")
            return
        }
        navigationController?.pushViewController(AnnotationViewController(image: image, host: host), animated: true)
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

// MARK: - Pro：截图历史（Application Support，按设备分组保留）
private struct ScreenshotRecord: Codable {
    let id: String
    let date: TimeInterval
    let device: String
    let file: String
}

private enum ScreenshotHistory {
    static let maxCount = 60
    private static let indexKey = "adbweb.screenshot.history.v1"
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("adbweb.screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func all() -> [ScreenshotRecord] {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([ScreenshotRecord].self, from: data) else { return [] }
        return list
    }

    private static func persist(_ list: [ScreenshotRecord]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: indexKey)
    }

    static func save(_ image: UIImage, host: AdbHost) {
        guard let data = image.pngData() else { return }
        let record = ScreenshotRecord(
            id: UUID().uuidString,
            date: Date().timeIntervalSince1970,
            device: host.serial,
            file: "\(UUID().uuidString).png"
        )
        try? data.write(to: directory.appendingPathComponent(record.file), options: .atomic)
        var list = all()
        list.insert(record, at: 0)
        persist(Array(list.prefix(maxCount)))
    }

    static func remove(_ record: ScreenshotRecord) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.file))
        persist(all().filter { $0.id != record.id })
    }

    static func image(for record: ScreenshotRecord) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(record.file).path)
    }
}

// MARK: - Pro：截图历史列表
private final class ScreenshotHistoryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private var records = ScreenshotHistory.all()
    private let table: UITableView = {
        let t = UITableView(frame: .zero, style: .insetGrouped)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "shot")
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "截图历史"
        view.backgroundColor = .systemBackground
        table.dataSource = self
        table.delegate = self
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        records = ScreenshotHistory.all()
        table.reloadData()
    }

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { records.count }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "shot", for: indexPath)
        let record = records[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = "\(record.device) · 截图"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        cfg.secondaryText = formatter.string(from: Date(timeIntervalSince1970: record.date))
        cfg.secondaryTextProperties.color = .secondaryLabel
        if let image = ScreenshotHistory.image(for: record) {
            cfg.image = thumbnail(image, maxSide: 56)
        }
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let detail = ScreenshotDetailViewController(record: records[indexPath.row])
        navigationController?.pushViewController(detail, animated: true)
    }

    func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        ScreenshotHistory.remove(records.remove(at: indexPath.row))
        tv.deleteRows(at: [indexPath], with: .automatic)
    }

    private func thumbnail(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(maxSide / image.size.width, maxSide / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

private final class ScreenshotDetailViewController: UIViewController {
    private let record: ScreenshotRecord
    private let imageView = UIImageView()

    init(record: ScreenshotRecord) {
        self.record = record
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "截图详情"
        view.backgroundColor = .systemBackground
        imageView.image = ScreenshotHistory.image(for: record)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .secondarySystemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.accessibilityLabel = "截图内容"
        view.addSubview(imageView)

        let share = UIButton(type: .system)
        share.setTitle("分享 / 保存", for: .normal)
        share.titleLabel?.font = .boldSystemFont(ofSize: 15)
        share.accessibilityLabel = "分享或保存这张截图"
        share.addTarget(self, action: #selector(shareImage), for: .touchUpInside)

        let delete = UIButton(type: .system)
        delete.setTitle("删除", for: .normal)
        delete.titleLabel?.font = .boldSystemFont(ofSize: 15)
        delete.tintColor = .systemRed
        delete.accessibilityLabel = "删除这张截图"
        delete.addTarget(self, action: #selector(deleteImage), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [share, delete])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 16
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
    }

    @objc private func shareImage() {
        guard let image = imageView.image else { return }
        let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        present(av, animated: true)
    }

    @objc private func deleteImage() {
        ScreenshotHistory.remove(record)
        navigationController?.popViewController(animated: true)
    }
}

// MARK: - Pro：截图标注
private final class DrawingCanvas: UIView {
    var strokes: [(points: [CGPoint], color: UIColor)] = []
    var currentColor: UIColor = .systemRed

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        strokes.append((points: [point], color: currentColor))
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        for stroke in strokes {
            stroke.color.setStroke()
            let path = UIBezierPath()
            for (index, point) in stroke.points.enumerated() {
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    func clear() {
        strokes.removeAll()
        setNeedsDisplay()
    }
}

final class AnnotationViewController: UIViewController {
    private let image: UIImage
    private let host: AdbHost
    private let canvas = DrawingCanvas()
    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.text = "用手指在画面上标注，保存后会写入截图历史并可选存到相册"
        return l
    }()

    init(image: UIImage, host: AdbHost) {
        self.image = image
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "截图标注"
        view.backgroundColor = .systemBackground

        let container = UIView()
        container.backgroundColor = .secondarySystemBackground
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let base = UIImageView(image: image)
        base.contentMode = .scaleAspectFit
        base.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(base)

        canvas.backgroundColor = .clear
        canvas.isUserInteractionEnabled = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.accessibilityLabel = "标注画布"
        container.addSubview(canvas)

        let red = UIButton(type: .system); red.setTitle("红笔", for: .normal)
        let blue = UIButton(type: .system); blue.setTitle("蓝笔", for: .normal)
        let green = UIButton(type: .system); green.setTitle("绿笔", for: .normal)
        let clear = UIButton(type: .system); clear.setTitle("清除", for: .normal)
        let save = UIButton(type: .system); save.setTitle("保存", for: .normal)
        save.titleLabel?.font = .boldSystemFont(ofSize: 15)
        [red, blue, green, clear, save].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.heightAnchor.constraint(equalToConstant: 44).isActive = true
            $0.accessibilityLabel = $0.title(for: .normal)
        }
        red.tintColor = .systemRed; blue.tintColor = .systemBlue; green.tintColor = .systemGreen
        red.addTarget(self, action: #selector(pickRed), for: .touchUpInside)
        blue.addTarget(self, action: #selector(pickBlue), for: .touchUpInside)
        green.addTarget(self, action: #selector(pickGreen), for: .touchUpInside)
        clear.addTarget(self, action: #selector(clearCanvas), for: .touchUpInside)
        save.addTarget(self, action: #selector(saveAnnotated), for: .touchUpInside)

        let colors = UIStackView(arrangedSubviews: [red, blue, green])
        colors.axis = .horizontal; colors.distribution = .fillEqually; colors.spacing = 8
        let actions = UIStackView(arrangedSubviews: [clear, save])
        actions.axis = .horizontal; actions.distribution = .fillEqually; actions.spacing = 8
        let toolbar = UIStackView(arrangedSubviews: [colors, actions, statusLabel])
        toolbar.axis = .vertical; toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            container.heightAnchor.constraint(equalTo: container.widthAnchor,
                                              multiplier: image.size.height / image.size.width),
            base.topAnchor.constraint(equalTo: container.topAnchor),
            base.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            base.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            base.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: container.bottomAnchor, constant: 16),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    @objc private func pickRed() { canvas.currentColor = .systemRed }
    @objc private func pickBlue() { canvas.currentColor = .systemBlue }
    @objc private func pickGreen() { canvas.currentColor = .systemGreen }
    @objc private func clearCanvas() { canvas.clear() }

    @objc private func saveAnnotated() {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        let output = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            guard canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
            let sx = image.size.width / canvas.bounds.width
            let sy = image.size.height / canvas.bounds.height
            for stroke in canvas.strokes {
                stroke.color.setStroke()
                let path = UIBezierPath()
                for (index, point) in stroke.points.enumerated() {
                    let scaled = CGPoint(x: point.x * sx, y: point.y * sy)
                    if index == 0 { path.move(to: scaled) } else { path.addLine(to: scaled) }
                }
                path.lineWidth = 4 * sx
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
        }
        ScreenshotHistory.save(output, host: host)
        UIImageWriteToSavedPhotosAlbum(output, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
        statusLabel.text = "已保存到截图历史，正在写入相册…"
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        statusLabel.text = error == nil ? "✅ 已标注并保存" : "已存入截图历史；相册保存失败：\(error!.localizedDescription)"
    }
}

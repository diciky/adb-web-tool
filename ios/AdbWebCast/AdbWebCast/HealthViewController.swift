import UIKit

/// 健康监控页：直连电视用 ADB shell 采集 CPU / 内存 / 存储 / 电量 / WiFi，
/// 每 2 秒采样一次，曲线保留最近 60 点；网络测速用 ping + push/pull 吞吐。
/// 不依赖 Web 服务端，完全端上完成。

// MARK: - 极简折线图（自绘，无第三方依赖）
final class SparklineView: UIView {
    var values: [Double] = []
    var lineColor: UIColor = .systemBlue
    var maxValue: Double = 100

    override func draw(_ rect: CGRect) {
        guard values.count > 1, rect.width > 0, rect.height > 0 else { return }
        let path = UIBezierPath()
        let denom = CGFloat(max(values.count - 1, 1))
        let stepX = rect.width / denom
        for (i, raw) in values.enumerated() {
            let v = max(0, min(raw, maxValue))
            let y = rect.height - CGFloat(v / maxValue) * rect.height
            let p = CGPoint(x: CGFloat(i) * stepX, y: y)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        lineColor.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.stroke()
    }
}

private struct HealthSample {
    var cpu: Double? = nil
    var memPercent: Double = 0
    var memUsed: Int64 = 0
    var memTotal: Int64 = 0
    var storages: [(mount: String, percent: Int, used: Int64, total: Int64)] = []
    var batteryLevel: Int? = nil
    var batteryTempC: Double? = nil
    var wifiSSID: String = ""
    var wifiRx: Int? = nil
    var wifiRssi: Int? = nil
    var hasData: Bool = false
}

final class HealthViewController: UIViewController {

    private let host: AdbHost
    private let maxPoints = 60
    private var cpuValues: [Double] = []
    private var memValues: [Double] = []
    private var prevCpu: (idle: Double, total: Double)? = nil
    private var sampleTimer: Timer?
    private let workQueue = DispatchQueue(label: "adbweb.health.sample", qos: .utility)
    private var sampling = false
    private var testing = false

    private let scroll = UIScrollView()
    private let stack: UIStackView = {
        let s = UIStackView(); s.axis = .vertical; s.spacing = 12
        s.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        s.isLayoutMarginsRelativeArrangement = true
        return s
    }()
    private let cpuChart = SparklineView()
    private let memChart = SparklineView()
    private let cpuLabel = HealthViewController.makeCaption()
    private let memLabel = HealthViewController.makeCaption()
    private let statusLabel = HealthViewController.makeCaption()
    private let infoLabel = HealthViewController.makeCaption()
    private let netLabel: UILabel = {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        l.numberOfLines = 0; l.text = "点「网络测速」测量电视到互联网的延迟与 ADB 传输吞吐。"; return l
    }()
    private let storageStack: UIStackView = {
        let s = UIStackView(); s.axis = .vertical; s.spacing = 6; return s
    }()
    private let pauseButton: UIButton = {
        let b = UIButton(type: .system); b.setTitle("暂停", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.accessibilityLabel = "暂停或继续健康采样"; return b
    }()
    private let testButton: UIButton = {
        let b = UIButton(type: .system); b.setTitle("网络测速", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        b.accessibilityLabel = "开始网络测速"; return b
    }()

    init(host: AdbHost) { self.host = host; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeCaption() -> UILabel {
        let l = UILabel(); l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel; return l
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "健康监控"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        cpuChart.lineColor = .systemBlue
        memChart.lineColor = .systemGreen
        cpuChart.backgroundColor = .secondarySystemBackground
        memChart.backgroundColor = .secondarySystemBackground
        cpuChart.layer.cornerRadius = 8
        memChart.layer.cornerRadius = 8
        cpuChart.accessibilityLabel = "CPU 使用率曲线"
        memChart.accessibilityLabel = "内存使用率曲线"
        statusLabel.text = "每 2s 采样 · 保留 \(maxPoints) 点 · 连接 \(host.serial)"

        let controls = UIStackView(arrangedSubviews: [statusLabel, pauseButton, testButton])
        controls.axis = .horizontal; controls.spacing = 8; controls.alignment = .center
        stack.addArrangedSubview(controls)
        stack.addArrangedSubview(card(title: "CPU 使用率 %", chart: cpuChart, caption: cpuLabel))
        stack.addArrangedSubview(card(title: "内存使用率 %", chart: memChart, caption: memLabel))
        stack.addArrangedSubview(sectionCard(title: "存储", body: storageStack))
        stack.addArrangedSubview(infoLabel)
        stack.addArrangedSubview(sectionCard(title: "网络测速", body: netLabel))

        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            cpuChart.heightAnchor.constraint(equalToConstant: 150),
            memChart.heightAnchor.constraint(equalToConstant: 150),
        ])

        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        testButton.addTarget(self, action: #selector(netTest), for: .touchUpInside)
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        sample()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sampleTimer?.invalidate(); sampleTimer = nil
    }
    deinit { sampleTimer?.invalidate() }

    private func card(title: String, chart: UIView, caption: UILabel) -> UIView {
        let box = UIStackView(); box.axis = .vertical; box.spacing = 6
        let h = UILabel(); h.text = title; h.font = .systemFont(ofSize: 15, weight: .semibold)
        box.addArrangedSubview(h); box.addArrangedSubview(chart); box.addArrangedSubview(caption)
        return wrapCard(box)
    }

    private func sectionCard(title: String, body: UIView) -> UIView {
        let box = UIStackView(); box.axis = .vertical; box.spacing = 6
        let h = UILabel(); h.text = title; h.font = .systemFont(ofSize: 15, weight: .semibold)
        box.addArrangedSubview(h); box.addArrangedSubview(body)
        return wrapCard(box)
    }

    private func wrapCard(_ body: UIView) -> UIView {
        let holder = UIView()
        holder.backgroundColor = .secondarySystemBackground
        holder.layer.cornerRadius = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: holder.topAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -12),
            body.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -12),
        ])
        return holder
    }

    @objc private func togglePause() {
        if sampleTimer != nil {
            sampleTimer?.invalidate(); sampleTimer = nil
            pauseButton.setTitle("继续", for: .normal)
            statusLabel.text = "已暂停采样"
        } else {
            pauseButton.setTitle("暂停", for: .normal)
            statusLabel.text = "每 2s 采样 · 保留 \(maxPoints) 点"
            sampleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.sample()
            }
            sample()
        }
    }

    // MARK: - 采样

    private func sample() {
        workQueue.async { [weak self] in
            guard let self, !self.sampling else { return }
            self.sampling = true
            defer { self.sampling = false }
            let client = AdbClient()
            var snap = HealthSample()
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                let stat = try client.shell("cat /proc/stat", timeout: 15)
                let cur = HealthViewController.parseCpuTotal(stat)
                if let cur, let prev = self.prevCpu {
                    let dTotal = cur.total - prev.total
                    snap.cpu = dTotal > 0 ? max(0, min(100, (1 - (cur.idle - prev.idle) / dTotal) * 100)) : 0
                }
                self.prevCpu = cur

                let mem = try client.shell("cat /proc/meminfo", timeout: 15)
                let m = HealthViewController.parseMem(mem)
                snap.memPercent = m.percent; snap.memUsed = m.used; snap.memTotal = m.total

                if let df = try? client.shell("df -P 2>/dev/null", timeout: 15) {
                    snap.storages = HealthViewController.parseStorage(df)
                }
                if let bat = try? client.shell("dumpsys battery", timeout: 15) {
                    let lvl = HealthViewController.numberAfter("level:", in: bat)
                    let tmp = HealthViewController.numberAfter("temperature:", in: bat)
                    snap.batteryLevel = lvl.map { Int($0) }
                    snap.batteryTempC = tmp.map { $0 / 10 }
                }
                if let wifi = try? client.shell("dumpsys wifi", timeout: 15) {
                    snap.wifiSSID = HealthViewController.textAfter("SSID:", in: wifi)
                    snap.wifiRx = HealthViewController.numberAfter("mRxLinkSpeed:", in: wifi).map { Int($0) }
                    snap.wifiRssi = HealthViewController.numberAfter("mRssi:", in: wifi).map { Int($0) }
                }
                snap.hasData = true
            } catch {
                AdbLog.log("健康采样失败: \(error.localizedDescription)", level: "W")
            }
            client.disconnect()
            DispatchQueue.main.async { self.apply(snap) }
        }
    }

    private func apply(_ s: HealthSample) {
        guard s.hasData else {
            statusLabel.text = "采样失败 · 请确认电视已授权 ADB 后重试"
            return
        }
        if let cpu = s.cpu {
            cpuValues.append(cpu)
            if cpuValues.count > maxPoints { cpuValues.removeFirst(cpuValues.count - maxPoints) }
            cpuChart.values = cpuValues
            cpuChart.setNeedsDisplay()
            cpuLabel.text = String(format: "当前 %.0f%%", cpu)
        }
        memValues.append(s.memPercent)
        if memValues.count > maxPoints { memValues.removeFirst(memValues.count - maxPoints) }
        memChart.values = memValues
        memChart.setNeedsDisplay()
        memLabel.text = "已用 \(HealthViewController.fmt(s.memUsed)) / \(HealthViewController.fmt(s.memTotal))"

        storageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in s.storages {
            let line = UIStackView(); line.axis = .horizontal; line.spacing = 8; line.alignment = .center
            let name = UILabel(); name.text = row.mount; name.font = .systemFont(ofSize: 12)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let bar = UIProgressView(progressViewStyle: .default)
            bar.progress = Float(row.percent) / 100
            bar.progressTintColor = row.percent > 85 ? .systemRed : .systemBlue
            let val = UILabel()
            val.text = "\(row.percent)% · \(HealthViewController.fmt(row.used))/\(HealthViewController.fmt(row.total))"
            val.font = .systemFont(ofSize: 12); val.textColor = .secondaryLabel
            val.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            line.addArrangedSubview(name); line.addArrangedSubview(bar); line.addArrangedSubview(val)
            storageStack.addArrangedSubview(line)
        }

        var bits: [String] = []
        if let lvl = s.batteryLevel { bits.append("电量 \(lvl)%") }
        if let t = s.batteryTempC { bits.append("温度 \(String(format: "%.1f", t))°C") }
        if !s.wifiSSID.isEmpty { bits.append("WiFi \(s.wifiSSID)") }
        if let rx = s.wifiRx { bits.append("\(rx)Mbps") }
        if let rssi = s.wifiRssi { bits.append("RSSI \(rssi)") }
        infoLabel.text = bits.isEmpty ? "—" : bits.joined(separator: " · ")
        if sampleTimer != nil { statusLabel.text = "每 2s 采样 · 保留 \(maxPoints) 点 · \(host.serial)" }
    }

    // MARK: - 网络测速

    @objc private func netTest() {
        guard !testing else { return }
        testing = true
        testButton.isEnabled = false
        netLabel.text = "测速中…（ping + 5MB 推拉）"
        workQueue.async { [weak self] in
            guard let self else { return }
            let client = AdbClient()
            var lines: [String] = []
            do {
                try client.connect(host: self.host.ip, port: self.host.port)
                let pingOut = try client.shell("ping -c 4 -W 2 8.8.8.8 2>/dev/null", timeout: 40)
                lines.append(HealthViewController.parsePing(pingOut))

                let size = 2 * 1024 * 1024
                let local = FileManager.default.temporaryDirectory.appendingPathComponent("adbweb_speed_\(UUID().uuidString).bin")
                let remote = "/data/local/tmp/adbweb_speed.bin"
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("adbweb_speed_out_\(UUID().uuidString).bin")
                defer {
                    try? FileManager.default.removeItem(at: local)
                    try? FileManager.default.removeItem(at: out)
                    _ = try? client.shell("rm -f \(remote)", timeout: 15)
                }
                let blob = Data(repeating: 7, count: size)
                try blob.write(to: local)
                let t0 = Date()
                try client.push(localURL: local, remotePath: remote, progress: { _ in })
                let pushSec = max(Date().timeIntervalSince(t0), 0.001)
                let t1 = Date()
                try client.pull(remotePath: remote, to: out, progress: { _ in })
                let pullSec = max(Date().timeIntervalSince(t1), 0.001)
                lines.append(String(format: "ADB 推送 %.2f MB/s · 拉取 %.2f MB/s", 2.0 / pushSec, 2.0 / pullSec))
            } catch {
                lines.append("测速失败：\(error.localizedDescription)")
            }
            client.disconnect()
            DispatchQueue.main.async {
                self.netLabel.text = lines.joined(separator: "\n")
                self.testing = false
                self.testButton.isEnabled = true
            }
        }
    }

    // MARK: - 解析（纯函数）

    private static func parseCpuTotal(_ text: String) -> (idle: Double, total: Double)? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("cpu ") }) else { return nil }
        let nums = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard nums.count >= 5 else { return nil }
        return (nums[3] + nums[4], nums.reduce(0, +))
    }

    private static func parseMem(_ text: String) -> (percent: Double, used: Int64, total: Int64) {
        var table: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard let first = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let v = Int64(first) else { continue }
            table[key] = v * 1024
        }
        let total = table["MemTotal"] ?? 0
        let avail = table["MemAvailable"] ?? table["MemFree"] ?? 0
        let used = max(0, total - avail)
        return (total > 0 ? Double(used) / Double(total) * 100 : 0, used, total)
    }

    private static func parseStorage(_ text: String) -> [(mount: String, percent: Int, used: Int64, total: Int64)] {
        var rows: [(mount: String, percent: Int, used: Int64, total: Int64)] = []
        for line in text.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == " " }).map(String.init)
            guard cols.count >= 6, cols[4].hasSuffix("%") else { continue }
            let mount = cols[5]
            guard mount == "/" || mount == "/system" || mount == "/sdcard" ||
                  mount.hasPrefix("/data") || mount.hasPrefix("/storage") else { continue }
            let total = (Int64(cols[1]) ?? 0) * 1024
            let used = (Int64(cols[2]) ?? 0) * 1024
            let pct = Int(String(cols[4].dropLast())) ?? 0
            rows.append((mount, pct, used, total))
        }
        return rows
    }

    private static func numberAfter(_ key: String, in text: String) -> Double? {
        guard let range = text.range(of: key) else { return nil }
        var digits = ""
        var started = false
        for ch in text[range.upperBound...] {
            if ch.isNumber || (ch == "-" && !started) {
                digits.append(ch); started = true
            } else if started { break }
        }
        return started ? Double(digits) : nil
    }

    private static func textAfter(_ key: String, in text: String) -> String {
        guard let range = text.range(of: key) else { return "" }
        let tail = text[range.upperBound...]
        if let nl = tail.firstIndex(of: "\n") { return String(tail[..<nl]).trimmingCharacters(in: .whitespaces) }
        return tail.trimmingCharacters(in: .whitespaces)
    }

    private static func parsePing(_ text: String) -> String {
        // 丢包在 "0% packet loss" 里，取 loss 前面的整数
        var loss = "?"
        if let lossRange = text.range(of: "% packet loss") {
            let head = text[..<lossRange.lowerBound]
            if let space = head.lastIndex(of: " ") {
                loss = String(text[text.index(after: space)..<lossRange.lowerBound]) + "%"
            }
        }
        guard let range = text.range(of: "min/avg/max") else { return "Ping 失败（电视可能无外网）· 丢包 \(loss)" }
        let tail = text[range.lowerBound...]
        let vals = tail.split(separator: " ").first(where: { $0.contains("/") }).map(String.init) ?? ""
        if vals.isEmpty { return "Ping 失败 · 丢包 \(loss)" }
        return "Ping 延迟 \(vals) ms · 丢包 \(loss)"
    }

    private static func fmt(_ n: Int64) -> String {
        if n <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i] as NSString)
    }
}

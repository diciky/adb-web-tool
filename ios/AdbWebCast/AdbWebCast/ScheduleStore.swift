import Foundation

/// 定时任务：本地持久化 + App 内定时轮询执行。
/// 说明：iOS 不允许普通 App 在后台长期运行，任务在 App 处于前台时按计划触发；
/// 每次触发通过 ADB shell 对记录的电视设备执行动作。
struct ScheduleJob: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String = ""
    var action: String = "reboot"       // reboot / shutdown / wake / sleep / uninstall / clearData / forceStop
    var pkg: String = ""
    var mode: String = "interval"       // interval / cron
    var intervalSec: Int = 3600
    var cron: String = "0 3 * * *"
    var hostIP: String = ""
    var hostPort: UInt16 = 5555
    var nextRun: Date = Date()
    var paused: Bool = false
    var lastResult: String = ""

    static let actions: [(String, String)] = [
        ("reboot", "重启"), ("shutdown", "关机"), ("wake", "唤醒"), ("sleep", "熄屏"),
        ("uninstall", "卸载应用"), ("clearData", "清除数据"), ("forceStop", "强制停止"),
    ]
    var actionTitle: String { ScheduleJob.actions.first { $0.0 == action }?.1 ?? action }
    var needsPkg: Bool { ["uninstall", "clearData", "forceStop"].contains(action) }

    func command() -> String? {
        switch action {
        case "reboot": return "reboot"
        case "shutdown": return "reboot -p"
        case "wake": return "input keyevent 224"
        case "sleep": return "input keyevent 223"
        case "uninstall": return pkg.isEmpty ? nil : "pm uninstall \(pkg)"
        case "clearData": return pkg.isEmpty ? nil : "pm clear \(pkg)"
        case "forceStop": return pkg.isEmpty ? nil : "am force-stop \(pkg)"
        default: return nil
        }
    }
}

final class ScheduleStore {
    static let shared = ScheduleStore()
    private let key = "adbweb.schedules.v1"
    private let lock = NSLock()
    private var jobs: [ScheduleJob] = []
    private var timer: Timer?
    private var running = false
    private let queue = DispatchQueue(label: "adbweb.schedule.run", qos: .utility)

    private init() {
        load()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScheduleJob].self, from: data) else { return }
        jobs = decoded
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - 增删改查

    func all() -> [ScheduleJob] {
        lock.lock(); defer { lock.unlock() }
        return jobs.sorted { $0.nextRun < $1.nextRun }
    }

    @discardableResult
    func add(_ job: ScheduleJob) -> ScheduleJob {
        lock.lock()
        var j = job
        j.id = UUID().uuidString
        j.nextRun = ScheduleStore.computeNext(j, from: Date())
        jobs.append(j)
        persist()
        lock.unlock()
        return j
    }

    func remove(id: String) {
        lock.lock(); jobs.removeAll { $0.id == id }; persist(); lock.unlock()
    }

    func togglePause(id: String) {
        lock.lock()
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].paused.toggle(); persist() }
        lock.unlock()
    }

    /// 立即执行（异步），完成后回调主线程
    func runNow(id: String, done: @escaping (String) -> Void) {
        lock.lock()
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        var job = jobs[idx]
        lock.unlock()
        queue.async {
            let result = ScheduleStore.execute(job)
            DispatchQueue.main.async {
                self.lock.lock()
                if let i = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[i].lastResult = result
                    self.jobs[i].nextRun = ScheduleStore.computeNext(job, from: Date())
                    job = self.jobs[i]
                    self.persist()
                }
                self.lock.unlock()
                done(result)
            }
        }
    }

    // MARK: - App 内轮询

    func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    func stopTicking() {
        timer?.invalidate(); timer = nil
    }

    private func tick() {
        guard !running else { return }
        let now = Date()
        lock.lock()
        let due = jobs.enumerated().filter { !$0.element.paused && $0.element.nextRun <= now }.map { $0.element }
        lock.unlock()
        guard !due.isEmpty else { return }
        running = true
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.running = false }
            for var job in due {
                let result = ScheduleStore.execute(job)
                self.lock.lock()
                if let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                    self.jobs[i].lastResult = result
                    self.jobs[i].nextRun = ScheduleStore.computeNext(job, from: Date())
                    job = self.jobs[i]
                }
                self.lock.unlock()
                AdbLog.log("定时任务 \(job.name) 执行：\(result)")
            }
            self.lock.lock(); self.persist(); self.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .scheduleJobsChanged, object: nil)
            }
        }
    }

    // MARK: - 执行 & Cron

    private static func execute(_ job: ScheduleJob) -> String {
        guard let cmd = job.command() else { return "失败：任务缺少包名" }
        let client = AdbClient()
        do {
            try client.connect(host: job.hostIP, port: job.hostPort)
            _ = try client.shell(cmd, timeout: 30)
            client.disconnect()
            return "成功 · \(ScheduleStore.shortTime(Date()))"
        } catch {
            client.disconnect()
            return "失败：\(error.localizedDescription)"
        }
    }

    static func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    static func computeNext(_ job: ScheduleJob, from: Date) -> Date {
        if job.mode == "interval" {
            return from.addingTimeInterval(TimeInterval(max(60, job.intervalSec)))
        }
        var t = from
        t = t.addingTimeInterval(60)
        guard let comps = parseCron(job.cron) else { return from.addingTimeInterval(86400) }
        let cal = Calendar.current
        var probe = cal.dateInterval(of: .minute, for: t)?.start ?? t
        // 最多向前找 7 天（每分钟一步）；非法/极稀疏表达式回退到 +1 天，避免主线程卡顿
        for _ in 0..<(1440 * 7) {
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: probe)
            if cronMatch(comps, minute: c.minute ?? 0, hour: c.hour ?? 0,
                         day: c.day ?? 1, month: c.month ?? 1, weekday: c.weekday ?? 1) {
                return probe
            }
            probe = probe.addingTimeInterval(60)
        }
        return from.addingTimeInterval(86400)
    }

    private static func parseCron(_ expr: String) -> [String]? {
        let f = expr.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " }).map(String.init)
        return f.count == 5 ? f : nil
    }

    private static func cronMatch(_ f: [String], minute: Int, hour: Int, day: Int, month: Int, weekday: Int) -> Bool {
        let dow7 = weekday == 1 ? 7 : weekday  // 日历 weekday 周日=1，cron 周日=7
        return fieldMatch(f[0], minute) && fieldMatch(f[1], hour) &&
               fieldMatch(f[2], day) && fieldMatch(f[3], month) && fieldMatch(f[4], dow7)
    }

    private static func fieldMatch(_ spec: String, _ val: Int) -> Bool {
        if spec == "*" || spec.isEmpty { return true }
        for part in spec.split(separator: ",") {
            if part.contains("/") {
                let seg = part.split(separator: "/")
                guard seg.count == 2, let step = Int(seg[1]), step > 0 else { continue }
                if seg[0] == "*" {
                    if val % step == 0 { return true }
                } else {
                    let range = seg[0].split(separator: "-").compactMap { Int($0) }
                    if range.count == 2, val >= range[0], val <= range[1], (val - range[0]) % step == 0 { return true }
                }
            } else if part.contains("-") {
                let range = part.split(separator: "-").compactMap { Int($0) }
                if range.count == 2, val >= range[0], val <= range[1] { return true }
            } else if Int(part) == val { return true }
        }
        return false
    }
}

extension Notification.Name {
    static let scheduleJobsChanged = Notification.Name("scheduleJobsChanged")
}

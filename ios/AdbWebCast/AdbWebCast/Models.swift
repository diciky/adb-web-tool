import Foundation

/// 远端文件/目录（sync LIST 解析结果）
struct RemoteFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let mtime: Date
    let mode: UInt32

    func hash(into hasher: inout Hasher) { hasher.combine(path) }
    static func == (l: RemoteFile, r: RemoteFile) -> Bool { l.path == r.path }
}

/// 已安装应用
struct AppInfo: Identifiable, Hashable {
    let id = UUID()
    let pkg: String
    let path: String
    var name: String
    var versionName: String
    var isSystem: Bool
    var isDisabled: Bool

    func hash(into hasher: inout Hasher) { hasher.combine(pkg) }
    static func == (l: AppInfo, r: AppInfo) -> Bool { l.pkg == r.pkg }
}

/// 自启项（BOOT_COMPLETED receiver）
struct AutostartEntry: Identifiable, Hashable {
    let id = UUID()
    let pkg: String
    let component: String
    var enabled: Bool

    func hash(into hasher: inout Hasher) { hasher.combine(component) }
    static func == (l: AutostartEntry, r: AutostartEntry) -> Bool { l.component == r.component }
}

/// 设备信息
struct DeviceInfo {
    var model = ""
    var brand = ""
    var androidVersion = ""
    var sdk = ""
    var manufacturer = ""
    var serialno = ""
    var ip = ""
    var cpu = ""
    var resolution = ""
    var battery = ""
}

/// 批量任务动作
enum BatchAction: String, CaseIterable {
    case reboot = "重启"
    case shutdown = "关机"
    case recovery = "重启到 Recovery"
    case sleep = "休眠"
    case wake = "唤醒"
    case forceStop = "强制停止应用"
    case clearData = "清除应用数据"
    case uninstall = "卸载应用"
}

import Foundation

/// 一台连接过的电视：IP/端口 + 记住的名字（型号或用户别名），以及是否已授权。
struct SavedDevice: Codable, Equatable {
    var ip: String
    var port: UInt16
    var name: String        // 型号或用户改名
    var alias: String = ""  // 用户自定义备注，优先于 name 显示
    var lastConnected: Date = Date()

    var displayName: String { alias.isEmpty ? name : alias }
    var key: String { "\(ip):\(port)" }

    static func == (l: SavedDevice, r: SavedDevice) -> Bool { l.key == r.key }
}

/// 本地持久化：连接过的设备 + 名字，存 UserDefaults。
/// 目标：连过一次后永久记住，下次直接显示，无需重新扫描/重新输入 IP。
enum DeviceStore {
    private static let key = "adb.saved.devices.v1"
    private static let defaults = UserDefaults.standard

    static func all() -> [SavedDevice] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedDevice].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SavedDevice]) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }

    /// 连接成功后记住设备；若已存在则更新名字与连接时间。
    static func remember(ip: String, port: UInt16, name: String) {
        var list = all()
        var dev = SavedDevice(ip: ip, port: port, name: name)
        if let idx = list.firstIndex(where: { $0.key == dev.key }) {
            dev = list[idx]
            if !name.isEmpty { dev.name = name }
            dev.lastConnected = Date()
            list[idx] = dev
        } else {
            list.append(dev)
        }
        save(list)
    }

    static func rename(ip: String, port: UInt16, alias: String) {
        var list = all()
        if let idx = list.firstIndex(where: { $0.ip == ip && $0.port == port }) {
            list[idx].alias = alias
            save(list)
        }
    }

    static func remove(ip: String, port: UInt16) {
        var list = all()
        list.removeAll { $0.ip == ip && $0.port == port }
        save(list)
    }

    static func contains(ip: String, port: UInt16) -> Bool {
        all().contains { $0.ip == ip && $0.port == port }
    }
}

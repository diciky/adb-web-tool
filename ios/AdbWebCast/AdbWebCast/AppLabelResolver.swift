import Foundation
import Compression

/// 从已安装 APK 解析应用显示名（优先中文）与启动图标，不依赖 Mac 侧 aapt。
///
/// - 一次 pull 同时拿到 `AndroidManifest.xml` / `resources.arsc` / 图标资源；
/// - 二进制 XML 取 `<application android:label>` 与 `android:icon`；
/// - 资源表按 zh-CN > zh > 默认 > 其他语言 解析字符串；
/// - 图标从 `res/<type>-<density>/<name>.png|webp` 提取；
/// - 结果按包名持久化到 Application Support（名称 + 图标 + APK 路径），避免重复拉包；
/// - 兼容旧 Caches 图标与旧名称缓存的自动迁移。
enum AppLabelResolver {

    // MARK: - Public

    struct AssetResult {
        let label: String?
        let iconData: Data?
        let apkPath: String?
    }

    /// 解析单个应用。缓存按包名存储，和 APK 路径解耦：
    /// 首次解析成功后，后续进应用/自启页只读本地缓存，不再拉 APK。
    static func assets(for pkg: String, apkPath: String, client: AdbClient) -> AssetResult {
        // 第一阶段：只读缓存，命中就完全不碰 ADB。
        let hit: AssetResult? = cacheQueue.sync {
            guard let cached = records[pkg], isFresh(cached) else { return nil }
            let pathChanged = !apkPath.isEmpty && !cached.apkPath.isEmpty && cached.apkPath != apkPath
            return pathChanged ? nil : result(from: cached, pkg: pkg)
        }
        if let hit = hit { return hit }

        // 第二阶段：未命中才拉 APK。应用页/自启页可能同时在后台解析，缓存写入统一进串行队列。
        guard let resolved = resolve(pkg: pkg, apkPath: apkPath, client: client) else {
            return cacheQueue.sync {
                let previous = records[pkg]
                let failed = CacheRecord(label: previous?.label,
                                         iconFile: previous?.iconFile,
                                         apkPath: apkPath.isEmpty ? (previous?.apkPath ?? "") : apkPath,
                                         resolvedAt: Date().timeIntervalSince1970)
                records[pkg] = failed
                saveRecords()
                return result(from: failed, pkg: pkg)
            }
        }

        return cacheQueue.sync {
            let previous = records[pkg]
            let finalLabel = previous?.label ?? resolved.label
            let finalIconData = loadIcon(file: previous?.iconFile, pkg: pkg) ?? resolved.iconData
            var iconFile = previous?.iconFile
            if iconFile == nil, let data = finalIconData {
                iconFile = saveIcon(data, pkg: pkg)
            }
            let record = CacheRecord(label: finalLabel,
                                     iconFile: iconFile,
                                     apkPath: resolved.apkPath ?? apkPath,
                                     resolvedAt: Date().timeIntervalSince1970)
            records[pkg] = record
            saveRecords()
            return AssetResult(label: finalLabel, iconData: finalIconData, apkPath: record.apkPath)
        }
    }

    /// 兼容旧调用：只取名称。
    static func label(for pkg: String, apkPath: String, client: AdbClient) -> String? {
        assets(for: pkg, apkPath: apkPath, client: client).label
    }

    /// 读取某个包的完整本地缓存；不触发网络。
    static func cached(pkg: String) -> AssetResult? {
        cacheQueue.sync {
            guard let record = records[pkg] else { return nil }
            return result(from: record, pkg: pkg)
        }
    }

    /// 该包资源是否已完整解析（名称 + 图标都有，或明确重试期未到）。
    /// 关键修复：只有名字没有图标的包（如旧版缓存的 Twitch/Emby）必须允许重试，
    /// 否则一旦被标记为 resolved 就永远不会再尝试补图标。
    static func isResolved(pkg: String) -> Bool {
        cacheQueue.sync {
            guard let r = records[pkg], r.resolvedAt > 0 else { return false }
            // 名称与图标齐全 → 完成
            if r.label != nil, r.iconFile != nil { return true }
            // 缺任意一项 → 超过重试间隔后重新解析（图标失败的包也有机会补上）
            return Date().timeIntervalSince1970 - r.resolvedAt < retryInterval
        }
    }

    /// 图标是否缺失（用于列表页优先补图标）。
    static func needsIcon(pkg: String) -> Bool {
        cacheQueue.sync {
            guard let r = records[pkg] else { return true }
            return r.iconFile == nil
        }
    }

    /// 强制刷新用：清除所有「不完整」记录（缺名字或缺图标的都清），
    /// 包括旧版本解析 bug 时期写入的大量失败记录——否则 24h 重试间隔内
    /// 升级新版的用户会一直看到纯包名列表。
    static func clearIncompleteRecords(pkgs: [String]) {
        cacheQueue.sync {
            var changed = false
            for p in pkgs {
                if let r = records[p], r.label == nil || r.iconFile == nil {
                    records.removeValue(forKey: p)
                    changed = true
                }
            }
            if changed { saveRecords() }
        }
    }

    /// 只查缓存，不触发网络/IO。apkPath 参数保留兼容，实际按包名查找。
    static func cachedLabel(pkg: String, apkPath: String) -> String? {
        cacheQueue.sync {
            if let label = records[pkg]?.label, !label.isEmpty { return label }
            return legacyLabel(pkg: pkg)
        }
    }

    /// 只查图标缓存；优先 Application Support，兼容迁移旧 Caches 图标。
    static func cachedIcon(pkg: String) -> Data? {
        cacheQueue.sync {
            if let record = records[pkg], let data = loadIcon(file: record.iconFile, pkg: pkg), !data.isEmpty {
                return data
            }
            return migrateLegacyIconLocked(pkg: pkg)
        }
    }

    // MARK: - Cache

    private struct CacheRecord: Codable {
        var label: String?
        var iconFile: String?
        var apkPath: String
        var resolvedAt: TimeInterval
    }

    // v3：旧 v2 缓存里大量包只有名字没有图标（资源映射/AAPT2 空条目问题），
    // 换 key 让这些包在升级后重新解析一次，补上图标；名称仍从 v1 迁移兜底。
    private static let cacheDefaultsKey = "adbweb.app.assets.v3"
    private static let legacyLabelsKey = "adbweb.app.labels.v1"
    private static let retryInterval: TimeInterval = 24 * 60 * 60
    private static let cacheQueue = DispatchQueue(label: "adbweb.app.assets.cache")

    private static let legacyLabels: [String: String] = {
        UserDefaults.standard.dictionary(forKey: legacyLabelsKey) as? [String: String] ?? [:]
    }()
    private static var records: [String: CacheRecord] = loadRecords()

    private static func isFresh(_ record: CacheRecord) -> Bool {
        if record.label != nil || record.iconFile != nil { return true }
        return Date().timeIntervalSince1970 - record.resolvedAt < retryInterval
    }

    private static func result(from record: CacheRecord, pkg: String) -> AssetResult {
        AssetResult(label: record.label,
                    iconData: loadIcon(file: record.iconFile, pkg: pkg),
                    apkPath: record.apkPath)
    }

    private static func loadRecords() -> [String: CacheRecord] {
        var result: [String: CacheRecord] = [:]
        if let data = UserDefaults.standard.data(forKey: cacheDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: CacheRecord].self, from: data) {
            result = decoded
        }
        // 迁移 v1 的名称缓存：旧键是 "包名|APK路径"，这里只取包名，修掉跨页面查不到的 bug。
        for (key, label) in legacyLabels {
            let pkg = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
            guard !pkg.isEmpty, result[pkg] == nil else { continue }
            result[pkg] = CacheRecord(label: label, iconFile: nil, apkPath: "", resolvedAt: 0)
        }
        return result
    }

    private static func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: cacheDefaultsKey)
    }

    private static func legacyLabel(pkg: String) -> String? {
        if let exact = legacyLabels[pkg], !exact.isEmpty { return exact }
        for (key, value) in legacyLabels where key == pkg || key.hasPrefix(pkg + "|") {
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func assetsDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("AdbWebCast/app-assets", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func safeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func iconFileName(pkg: String) -> String {
        safeFileName(pkg) + ".png"
    }

    private static func loadIcon(file: String?, pkg: String) -> Data? {
        if let file = file, !file.isEmpty,
           let dir = assetsDirectory(),
           let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
           !data.isEmpty {
            return data
        }
        return nil
    }

    private static func saveIcon(_ data: Data, pkg: String) -> String? {
        guard let dir = assetsDirectory(), !data.isEmpty else { return nil }
        let name = iconFileName(pkg: pkg)
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            return nil
        }
        return name
    }

    private static func legacyIconURL(pkg: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("adbweb-app-icons", isDirectory: true)
        return dir.appendingPathComponent(safeFileName(pkg) + ".icon")
    }

    /// 调用方必须持有 cacheQueue。
    private static func migrateLegacyIconLocked(pkg: String) -> Data? {
        guard let old = legacyIconURL(pkg: pkg), let data = try? Data(contentsOf: old), !data.isEmpty else { return nil }
        if let name = saveIcon(data, pkg: pkg), var record = records[pkg] {
            record.iconFile = name
            records[pkg] = record
            saveRecords()
        }
        return data
    }

    // MARK: - Resolve

    private static func resolve(pkg: String, apkPath: String, client: AdbClient) -> AssetResult? {
        var path = apkPath
        if path.isEmpty {
            let out = (try? client.shell("pm path \(pkg)", timeout: 30)) ?? ""
            if let line = out.split(separator: "\n").first(where: { $0.contains("package:") }) {
                path = line.replacingOccurrences(of: "package:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !path.isEmpty else {
            AdbLog.log("资源解析跳过 \(pkg)：无 APK 路径", level: "W")
            return nil
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset_\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try client.pull(remotePath: path, to: tmp, progress: { _ in })
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
            // 超大游戏包跳过，避免手机内存吃满；这类包回退包名与占位图标。
            guard size > 0, size <= 160 * 1024 * 1024 else {
                AdbLog.log("资源解析跳过 \(pkg)：APK 大小异常 \(size)B", level: "W")
                return nil
            }
            guard let data = try? Data(contentsOf: tmp, options: .mappedIfSafe) else {
                AdbLog.log("资源解析失败 \(pkg)：无法读取 APK 数据", level: "W")
                return nil
            }
            let bytes = Bytes(data)
            let entries = zipEntries(bytes)
            guard let manifestData = extract("AndroidManifest.xml", from: bytes, entries: entries),
                  let info = manifestInfo(in: manifestData) else {
                AdbLog.log("资源解析失败 \(pkg)：ZIP 条目 \(entries.count) 个，Manifest 解析失败", level: "W")
                return nil
            }

            var label: String?
            switch info.label {
            case .string(let value):
                label = cleanLabel(value)
            case .reference(let id):
                guard let arsc = extract("resources.arsc", from: bytes, entries: entries) else {
                    label = nil
                    break
                }
                label = resolveReference(id, in: arsc).flatMap(cleanLabel)
            case .none:
                label = nil
            }

            let icon = findIcon(iconId: info.iconId, bytes: bytes, entries: entries)
            AdbLog.log("资源解析完成 \(pkg)：名称=\(label ?? "无") 图标=\(icon == nil ? "无" : "\(icon!.count)B")")
            return AssetResult(label: label, iconData: icon, apkPath: path)
        } catch {
            AdbLog.log("解析应用资源失败 \(pkg): \(error.localizedDescription)", level: "W")
            return nil
        }
    }

    private static func cleanLabel(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 旧工具链可能把 UTF-16LE 按单字节解码，字符之间夹 0x00。
        if s.contains("\u{0}") {
            let scalarBytes = Array(s.utf8)
            if let fixed = String(bytes: scalarBytes, encoding: .utf16LittleEndian) {
                s = fixed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if s.isEmpty || s == "null" { return nil }
        return s
    }

    // MARK: - Binary XML

    private enum ManifestLabel {
        case string(String)
        case reference(UInt32)
    }

    private struct ManifestInfo {
        var label: ManifestLabel?
        var iconId: UInt32?
    }

    private static func manifestInfo(in xml: Data) -> ManifestInfo? {
        let b = Bytes(xml)
        guard b.has(0, 8), b.u16(0) == 0x0003 else { return nil }
        var pool: StringPool?
        var offset = Int(b.u16(2))
        let total = min(b.count, Int(b.u32(4)))

        while b.has(offset, 8), offset + 8 <= total {
            let type = b.u16(offset)
            let headerSize = Int(b.u16(offset + 2))
            let chunkSize = Int(b.u32(offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= total else { break }

            if type == 0x0001, pool == nil {
                pool = StringPool(b, offset: offset, chunkSize: chunkSize)
            } else if type == 0x0102 {
                if let pool = pool,
                   let info = applicationInfo(in: b, at: offset, headerSize: headerSize, pool: pool) {
                    return info
                }
            }
            offset += chunkSize
        }
        return nil
    }

    private static func applicationInfo(in b: Bytes, at offset: Int, headerSize: Int,
                                        pool: StringPool) -> ManifestInfo? {
        guard b.has(offset + 24, 8) else { return nil }
        let nameIndex = Int(b.u32(offset + 20))
        guard pool.strings.indices.contains(nameIndex), pool.strings[nameIndex] == "application" else { return nil }

        let attrStart = Int(b.u16(offset + 24))
        let attrSize = Int(b.u16(offset + 26))
        let attrCount = Int(b.u16(offset + 28))
        guard attrSize >= 20 else { return nil }
        var p = offset + headerSize + attrStart
        var info = ManifestInfo()
        for _ in 0..<attrCount {
            guard b.has(p, 20) else { break }
            let nameIndex = Int(b.u32(p + 4))
            let rawValue = b.u32(p + 8)
            let dataType = b.u8(p + 15)
            let data = b.u32(p + 16)
            let attrName = pool.strings.indices.contains(nameIndex) ? pool.strings[nameIndex] : ""
            if attrName == "label" {
                if dataType == 0x01 { info.label = .reference(data) }
                else if dataType == 0x03, pool.strings.indices.contains(Int(data)) {
                    info.label = .string(pool.strings[Int(data)])
                } else if rawValue != 0xFFFFFFFF, pool.strings.indices.contains(Int(rawValue)) {
                    info.label = .string(pool.strings[Int(rawValue)])
                }
            } else if attrName == "icon" {
                if dataType == 0x01 { info.iconId = data }
            }
            p += attrSize
        }
        return info.label == nil && info.iconId == nil ? nil : info
    }

    // MARK: - resources.arsc

    private static func resolveReference(_ id: UInt32, in arsc: Data, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        let b = Bytes(arsc)
        guard b.has(0, 8), b.u16(0) == 0x0002 else { return nil }
        let tableSize = min(b.count, Int(b.u32(4)))
        var offset = Int(b.u16(2))
        var globalPool: StringPool?

        while b.has(offset, 8), offset + 8 <= tableSize {
            let type = b.u16(offset)
            let headerSize = Int(b.u16(offset + 2))
            let chunkSize = Int(b.u32(offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= tableSize else { break }
            if type == 0x0001, globalPool == nil {
                globalPool = StringPool(b, offset: offset, chunkSize: chunkSize)
            } else if type == 0x0200 {
                if let name = resolveInPackage(id, b: b, packageOffset: offset,
                                               headerSize: headerSize, chunkSize: chunkSize,
                                               globalPool: globalPool, depth: depth) {
                    return name
                }
            }
            offset += chunkSize
        }
        return nil
    }

    private static func resolveInPackage(_ id: UInt32, b: Bytes, packageOffset: Int,
                                         headerSize: Int, chunkSize: Int,
                                         globalPool: StringPool?, depth: Int) -> String? {
        guard b.has(packageOffset + 288, 4) else { return nil }
        let packageId = b.u32(packageOffset + 8)
        guard packageId == (id >> 24) else { return nil }

        let packageEnd = packageOffset + chunkSize
        var offset = packageOffset + max(headerSize, 288)
        let targetType = (id >> 16) & 0xFF
        let targetEntry = Int(id & 0xFFFF)
        var bestScore = -1
        var best: String?

        while b.has(offset, 8), offset + 8 <= packageEnd {
            let type = b.u16(offset)
            let typeHeaderSize = Int(b.u16(offset + 2))
            let size = Int(b.u32(offset + 4))
            guard size >= 8, offset + size <= packageEnd else { break }

            if type == 0x0201, Int(b.u8(offset + 8)) == Int(targetType) {
                let entryCount = Int(b.u32(offset + 12))
                let entriesStart = Int(b.u32(offset + 16))
                let score = configScore(b, configOffset: offset + 20)
                if score > bestScore, targetEntry < entryCount {
                    let table = offset + typeHeaderSize
                    if b.has(table + targetEntry * 4, 4) {
                        let entryOffset = Int(b.u32(table + targetEntry * 4))
                        if entryOffset != 0xFFFFFFFF {
                            let entryPos = offset + entriesStart + entryOffset
                            if let name = stringValue(at: entryPos, b: b, globalPool: globalPool, depth: depth) {
                                best = name
                                bestScore = score
                            }
                        }
                    }
                }
            }
            offset += size
        }
        return best
    }

    private static func stringValue(at entryPos: Int, b: Bytes, globalPool: StringPool?,
                                    depth: Int) -> String? {
        guard b.has(entryPos, 4) else { return nil }
        let entrySize = Int(b.u16(entryPos))
        let flags = b.u16(entryPos + 2)
        guard flags & 0x0001 == 0 else { return nil }
        let valuePos = entryPos + entrySize
        guard b.has(valuePos, 8) else { return nil }
        let dataType = b.u8(valuePos + 3)
        let data = b.u32(valuePos + 4)
        if dataType == 0x03, let pool = globalPool, pool.strings.indices.contains(Int(data)) {
            return pool.strings[Int(data)]
        }
        if dataType == 0x01 {
            return resolveReference(data, in: Data(b.bytes), depth: depth + 1)
        }
        return nil
    }

    /// ResTable_config: 4B size + 2B mcc + 2B mnc + 2B language + 2B country
    private static func configScore(_ b: Bytes, configOffset: Int) -> Int {
        guard b.has(configOffset, 12) else { return 0 }
        let size = Int(b.u32(configOffset))
        guard size >= 12 else { return 1 }
        let language = decodeLocale(b.u16(configOffset + 8))
        let country = decodeLocale(b.u16(configOffset + 10))
        if language == "zh" && country == "CN" { return 4 }
        if language == "zh" { return 3 }
        if language.isEmpty { return 1 }
        return 0
    }

    private static func decodeLocale(_ packed: UInt16) -> String {
        var out = ""
        for shift in [0, 5, 10] {
            let v = Int((packed >> UInt16(shift)) & 0x1F)
            if v == 0 { break }
            out.append(Character(UnicodeScalar(0x61 + v)!))
        }
        return out
    }

    /// 资源 id → `类型/条目名`，例如 0x7f0e0000 → "mipmap/ic_launcher"。
    private static func entryName(for id: UInt32, in arsc: Data) -> String? {
        let b = Bytes(arsc)
        guard b.has(0, 8), b.u16(0) == 0x0002 else { return nil }
        let tableSize = min(b.count, Int(b.u32(4)))
        var offset = Int(b.u16(2))
        while b.has(offset, 8), offset + 8 <= tableSize {
            let type = b.u16(offset)
            let chunkSize = Int(b.u32(offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= tableSize else { break }
            if type == 0x0200, b.u32(offset + 8) == (id >> 24) {
                guard b.has(offset + 288, 4) else { return nil }
                let typeStrings = offset + Int(b.u32(offset + 268))
                let keyStrings = offset + Int(b.u32(offset + 276))
                guard let typePool = StringPool(b, offset: typeStrings, chunkSize: 0),
                      let keyPool = StringPool(b, offset: keyStrings, chunkSize: 0) else { return nil }
                let typeIndex = Int((id >> 16) & 0xFF) - 1
                let entryIndex = Int(id & 0xFFFF)
                guard typePool.strings.indices.contains(typeIndex) else { return nil }

                // 资源 ID 的 entry 序号并不是 key 字符串池下标；
                // 真正的 key.index 存在 ResTable_entry 的 +4 处。
                var typeOffset = offset + max(Int(b.u16(offset + 2)), 288)
                let packageEnd = offset + chunkSize
                while b.has(typeOffset, 8), typeOffset + 8 <= packageEnd {
                    let t = b.u16(typeOffset)
                    let tSize = Int(b.u32(typeOffset + 4))
                    guard tSize >= 8, typeOffset + tSize <= packageEnd else { break }
                    if t == 0x0201, Int(b.u8(typeOffset + 8)) == Int((id >> 16) & 0xFF) {
                        let entryCount = Int(b.u32(typeOffset + 12))
                        let entriesStart = Int(b.u32(typeOffset + 16))
                        if entryIndex < entryCount {
                            let table = typeOffset + Int(b.u16(typeOffset + 2))
                            if b.has(table + entryIndex * 4, 4) {
                                let entryOffset = Int(b.u32(table + entryIndex * 4))
                                if entryOffset != 0xFFFFFFFF {
                                    let entryPos = typeOffset + entriesStart + entryOffset
                                    if b.has(entryPos + 8, 4) {
                                        let keyIndex = Int(b.u32(entryPos + 4))
                                        if keyPool.strings.indices.contains(keyIndex) {
                                            return typePool.strings[typeIndex] + "/" + keyPool.strings[keyIndex]
                                        }
                                    }
                                }
                            }
                        }
                    }
                    typeOffset += tSize
                }
            }
            offset += chunkSize
        }
        return nil
    }

    // MARK: - Icon

    /// 从 resources.arsc 直接取资源条目的 value 字符串。
    /// mipmap/drawable 类型的 entry value 就是文件路径（如 "res/mipmap-xxxhdpi/ic_launcher.png"），
    /// 资源混淆包的路径 value 会随文件名同步重写，因此混淆包也能直查。
    private static func entryValueString(for id: UInt32, in arsc: Data) -> String? {
        let b = Bytes(arsc)
        guard b.has(0, 8), b.u16(0) == 0x0002 else { return nil }
        let tableSize = min(b.count, Int(b.u32(4)))
        var offset = Int(b.u16(2))
        var globalPool: StringPool?
        while b.has(offset, 8), offset + 8 <= tableSize {
            let type = b.u16(offset)
            let headerSize = Int(b.u16(offset + 2))
            let chunkSize = Int(b.u32(offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= tableSize else { break }
            if type == 0x0001, globalPool == nil {
                globalPool = StringPool(b, offset: offset, chunkSize: chunkSize)
            } else if type == 0x0200 {
                if let value = valueStringInPackage(id, b: b, packageOffset: offset,
                                                    chunkSize: chunkSize,
                                                    headerSize: headerSize, globalPool: globalPool) {
                    return value
                }
            }
            offset += chunkSize
        }
        return nil
    }

    /// 在 package chunk 内查找指定资源的 STRING value（任一 config 块，路径字符串各 config 相同）。
    private static func valueStringInPackage(_ id: UInt32, b: Bytes, packageOffset: Int,
                                             chunkSize: Int, headerSize: Int,
                                             globalPool: StringPool?) -> String? {
        guard b.has(packageOffset + 288, 4) else { return nil }
        let packageId = b.u32(packageOffset + 8)
        guard packageId == (id >> 24) else { return nil }

        let packageEnd = packageOffset + chunkSize
        var offset = packageOffset + max(headerSize, 288)
        let targetType = (id >> 16) & 0xFF
        let targetEntry = Int(id & 0xFFFF)

        while b.has(offset, 8), offset + 8 <= packageEnd {
            let type = b.u16(offset)
            let typeHeaderSize = Int(b.u16(offset + 2))
            let size = Int(b.u32(offset + 4))
            guard size >= 8, offset + size <= packageEnd else { break }

            if type == 0x0201, Int(b.u8(offset + 8)) == Int(targetType) {
                let entryCount = Int(b.u32(offset + 12))
                let entriesStart = Int(b.u32(offset + 16))
                if targetEntry < entryCount {
                    let table = offset + typeHeaderSize
                    if b.has(table + targetEntry * 4, 4) {
                        let entryOffset = Int(b.u32(table + targetEntry * 4))
                        if entryOffset != 0xFFFFFFFF {
                            let entryPos = offset + entriesStart + entryOffset
                            // ResTable_entry：size(2) flags(2) key(4)，value 在 entrySize 偏移处
                            let entrySize = Int(b.u16(entryPos))
                            let valuePos = entryPos + entrySize
                            if b.has(valuePos + 8, 1) {
                                let dataType = b.u8(valuePos + 3)
                                let data = b.u32(valuePos + 4)
                                if dataType == 0x03, let pool = globalPool,
                                   pool.strings.indices.contains(Int(data)) {
                                    return pool.strings[Int(data)]
                                }
                            }
                        }
                    }
                }
            }
            offset += size
        }
        return nil
    }

    /// 在 binary XML（自适应图标 descriptor）里找 drawable 引用（@mipmap/@drawable 的资源 id）。
    private static func adaptiveIconReference(in xml: Data) -> UInt32? {
        let b = Bytes(xml)
        guard b.has(0, 8), b.u16(0) == 0x0003 else { return nil }
        var pool: StringPool?
        var offset = Int(b.u16(2))
        let total = min(b.count, Int(b.u32(4)))
        while b.has(offset, 8), offset + 8 <= total {
            let type = b.u16(offset)
            let headerSize = Int(b.u16(offset + 2))
            let chunkSize = Int(b.u32(offset + 4))
            guard chunkSize >= 8, offset + chunkSize <= total else { break }
            if type == 0x0001, pool == nil {
                pool = StringPool(b, offset: offset, chunkSize: chunkSize)
            } else if type == 0x0102, let pool = pool {
                let attrStart = Int(b.u16(offset + 24))
                let attrSize = Int(b.u16(offset + 26))
                let attrCount = Int(b.u16(offset + 28))
                guard attrSize >= 20 else { break }
                var p = offset + headerSize + attrStart
                for _ in 0..<attrCount {
                    guard b.has(p, 20) else { break }
                    let nameIndex = Int(b.u32(p + 4))
                    let dataType = b.u8(p + 15)
                    let data = b.u32(p + 16)
                    let attrName = pool.strings.indices.contains(nameIndex) ? pool.strings[nameIndex] : ""
                    if dataType == 0x01, data != 0xFFFFFFFF,
                       attrName == "drawable" || attrName == "foreground" || attrName == "background" {
                        return data
                    }
                    p += attrSize
                }
            }
            offset += chunkSize
        }
        return nil
    }

    private static func findIcon(iconId: UInt32?, bytes: Bytes,
                                 entries: [String: ZipEntry]) -> Data? {
        // 提取 resources.arsc：所有资源表反查（entryName/entryValueString）都必须传 arsc 数据，
        // 传整个 APK 字节会因首字节不是 RES_TABLE_TYPE(0x0002) 而恒返回 nil。
        let arscData = extract("resources.arsc", from: bytes, entries: entries)
        // 最优先：iconId → resources.arsc entry value 直接给出资源文件路径。
        // 资源混淆包（AndResGuard 等）改写实际文件名后，arsc 里的路径 value 会被同步重写，
        // 因此这是拿到真实图标文件（含混淆名）的最可靠途径，对静态图标 100% 命中。
        if let iconId = iconId, let arscData = arscData {
            if let valuePath = entryValueString(for: iconId, in: arscData) {
                let lower = valuePath.lowercased()
                if lower.hasSuffix(".png") || lower.hasSuffix(".webp") || lower.hasSuffix(".jpg") {
                    if let d = extract(valuePath, from: bytes, entries: entries), d.count > 64 {
                        return d
                    }
                } else if lower.hasSuffix(".xml") {
                    // 自适应图标 descriptor：解析 xml 里的 drawable 引用，再取引用资源的文件路径
                    if let xml = extract(valuePath, from: bytes, entries: entries),
                       let ref = adaptiveIconReference(in: xml),
                       let inner = entryValueString(for: ref, in: arscData),
                       let d = extract(inner, from: bytes, entries: entries), d.count > 64 {
                        return d
                    }
                }
            }
        }

        var candidates: [String] = []
        let densities = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi", "ldpi",
                         "anydpi", "anydpi-v26", "nodpi", ""]

        if let iconId = iconId, let arsc = arscData,
           let name = entryName(for: iconId, in: arsc),
           let slash = name.firstIndex(of: "/") {
            let type = String(name[..<slash])
            let key = String(name[name.index(after: slash)...])
            for ext in ["png", "webp", "jpg"] {
                for density in densities {
                    let dir = density.isEmpty ? "res/\(type)" : "res/\(type)-\(density)"
                    candidates.append("\(dir)/\(key).\(ext)")
                }
            }
            // 自适应图标：前景/背景单独存图，优先前景。
            for density in densities {
                    let dir = density.isEmpty ? "res/\(type)" : "res/\(type)-\(density)"
                    candidates.append("\(dir)/\(key)_foreground.png")
                    candidates.append("\(dir)/\(key)_background.png")
                    let v4Dir = density.isEmpty ? "res/\(type)" : "res/\(type)-\(density)-v4"
                    candidates.append("\(v4Dir)/\(key).png")
                    candidates.append("\(v4Dir)/\(key)_foreground.png")
            }
        }
        // 兜底：常见启动图标文件名。
        for key in ["ic_launcher", "app_icon", "launcher_icon", "icon"] {
            for type in ["mipmap", "drawable"] {
                for density in densities {
                    let dir = density.isEmpty ? "res/\(type)" : "res/\(type)-\(density)"
                    let v4Dir = density.isEmpty ? "res/\(type)" : "res/\(type)-\(density)-v4"
                    candidates.append("\(dir)/\(key).png")
                    candidates.append("\(v4Dir)/\(key).png")
                }
            }
        }
        for name in candidates {
            if let data = extract(name, from: bytes, entries: entries), data.count > 64 {
                return data
            }
        }
        // 二次兜底：固件常见 res/drawable-xhdpi-v4/ic_launcher.png 这类带版本后缀的目录，
        // 以及自适应图标 ic_launcher_foreground.png。按条目名模糊匹配。
        if let iconId = iconId, let arsc = arscData,
           let name = entryName(for: iconId, in: arsc),
           let slash = name.firstIndex(of: "/") {
            let type = String(name[..<slash])
            let key = String(name[name.index(after: slash)...])
            let keys = [key, key + "_foreground"]
            for entryName in entries.keys where entryName.hasPrefix("res/\(type)")
                && (entryName.hasSuffix(".png") || entryName.hasSuffix(".webp")) {
                let file = (entryName as NSString).lastPathComponent
                let base = (file as NSString).deletingPathExtension
                if keys.contains(base), let data = extract(entryName, from: bytes, entries: entries), data.count > 64 {
                    return data
                }
            }
        }

        // 三次兜底（关键）：部分 AAPT2 包的 android:icon 在资源表里是空条目
        // （entryOffset=0xffffffff），例如 Twitch 0x7f070058，导致上面全部落空。
        // 此时从包内图片资源里启发式挑一张最像启动图标的：
        // - 只看 res/mipmap* 与 res/drawable* 的 png/webp，排除 .9.png 拉伸图；
        // - 文件名含 icon/launcher/logo/app 关键词优先，mipmap 目录优先；
        // - 同等条件取体积较大者（通常即高密度启动图标）。
        struct IconCandidate { let name: String; let score: Int; let size: Int }
        var best: IconCandidate?
        let keywords = ["ic_launcher", "launcher", "app_icon", "logoicon", "logo", "icon", "app"]
        for (name, entry) in entries {
            guard name.hasPrefix("res/mipmap") || name.hasPrefix("res/drawable") else { continue }
            let lower = name.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".webp") else { continue }
            guard !lower.hasSuffix(".9.png") else { continue }
            let file = (name as NSString).lastPathComponent.lowercased()
            guard file.contains("icon") || file.contains("launch") || file.contains("logo") else { continue }
            // 启动图标通常 >= 2KB；小于 1KB 的多为占位/小图标
            guard entry.uncompressedSize >= 1024 else { continue }
            var score = 0
            if name.hasPrefix("res/mipmap") { score += 100 }
            for (idx, kw) in keywords.enumerated() where file.contains(kw) {
                score += (keywords.count - idx) * 10
                break
            }
            if let current = best {
                if score > current.score || (score == current.score && entry.uncompressedSize > current.size) {
                    best = IconCandidate(name: name, score: score, size: entry.uncompressedSize)
                }
            } else {
                best = IconCandidate(name: name, score: score, size: entry.uncompressedSize)
            }
        }
        if let best = best, let data = extract(best.name, from: bytes, entries: entries), data.count > 64 {
            return data
        }

        // 四次兕底（资源混淆包）：AndResGuard 等工具把 res 文件名混淆成 res/-A.png / res/m7.png，
        // 目录不再是 mipmap-/drawable-，以上全部落空（实测 SmartTube/TiviMate）。
        // 此时解出包内所有 res 图片的实际像素尺寸，优先选接近方形的最大图（启动图标特征），
        // 没有方形再退而取最大的图（banner/大图也能展示）。
        struct DimCandidate { let name: String; let width: Int; let height: Int; let byteSize: Int }
        var squareBest: DimCandidate?
        var anyBest: DimCandidate?
        for (name, entry) in entries {
            guard name.hasPrefix("res/") else { continue }
            let lower = name.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".webp") else { continue }
            guard !lower.hasSuffix(".9.png") else { continue }
            // 启动图标通常 1KB~1MB；太小的多为装饰小图
            guard entry.uncompressedSize >= 1024, entry.uncompressedSize <= 1_048_576 else { continue }
            guard let px = extract(name, from: bytes, entries: entries),
                  let dims = imageSize(px) else { continue }
            guard dims.width >= 48, dims.height >= 48 else { continue }
            let cand = DimCandidate(name: name, width: dims.width, height: dims.height,
                                    byteSize: entry.uncompressedSize)
            let square = abs(dims.width - dims.height) * 5 <= max(dims.width, dims.height)  // 长宽比 ≤ 1.2
            if square {
                if let cur = squareBest {
                    if max(dims.width, dims.height) > max(cur.width, cur.height) { squareBest = cand }
                } else { squareBest = cand }
            }
            if let cur = anyBest {
                if cand.byteSize > cur.byteSize { anyBest = cand }
            } else { anyBest = cand }
        }
        if let best = squareBest ?? anyBest,
           let picked = extract(best.name, from: bytes, entries: entries), picked.count > 64 {
            AdbLog.log("图标混淆兕底命中：\(best.name) \(best.width)x\(best.height)")
            return picked
        }
        return nil
    }

    /// 从 PNG/WebP 原始字节解析像素尺寸（资源混淆包兕底时用于挑启动图标）。
    private static func imageSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data)
        guard b.count >= 30 else { return nil }
        // PNG：8 字节签名 + IHDR，宽高在 16..24（大端）
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 {
            let w = (Int(b[16]) << 24) | (Int(b[17]) << 16) | (Int(b[18]) << 8) | Int(b[19])
            let h = (Int(b[20]) << 24) | (Int(b[21]) << 16) | (Int(b[22]) << 8) | Int(b[23])
            if w > 0, h > 0, w <= 8192, h <= 8192 { return (w, h) }
            return nil
        }
        // WebP：RIFF....WEBP
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 {
            if b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x58 {
                // VP8X（extended）：canvas 尺寸 24bit LE（值-1）在 24..30
                let w = 1 + (Int(b[24]) | (Int(b[25]) << 8) | (Int(b[26]) << 16))
                let h = 1 + (Int(b[27]) | (Int(b[28]) << 8) | (Int(b[29]) << 16))
                if w > 0, h > 0, w <= 8192, h <= 8192 { return (w, h) }
                return nil
            }
            if b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x20 {
                // VP8（lossy）：20 字节头 + frame tag(3) + start code(3)，宽高 14bit LE 在 26..30
                let w = Int(b[26]) | ((Int(b[27]) & 0x0F) << 8)
                let h = Int(b[28]) | ((Int(b[29]) & 0x0F) << 8)
                if w > 0, h > 0, w <= 8192, h <= 8192 { return (w, h) }
                return nil
            }
            if b[12] == 0x56, b[13] == 0x50, b[14] == 0x38, b[15] == 0x4C, b[20] == 0x2F {
                // VP8L（lossless）：signature 0x2F 后 14bit 宽-1、14bit 高-1（LSB first）
                let bits = UInt32(b[21]) | (UInt32(b[22]) << 8) | (UInt32(b[23]) << 16) | (UInt32(b[24]) << 24)
                let w = Int(bits & 0x3FFF) + 1
                let h = Int((bits >> 14) & 0x3FFF) + 1
                if w > 0, h > 0, w <= 8192, h <= 8192 { return (w, h) }
                return nil
            }
        }
        return nil
    }

    // MARK: - String pool

    private struct StringPool {
        let strings: [String]

        init?(_ b: Bytes, offset: Int, chunkSize: Int) {
            guard b.has(offset + 24, 4) else { return nil }
            let count = Int(b.u32(offset + 8))
            let flags = b.u32(offset + 16)
            let stringsStart = Int(b.u32(offset + 20))
            let headerSize = max(Int(b.u16(offset + 2)), 28)
            let utf8 = (flags & 0x100) != 0
            let base = offset + headerSize
            guard count >= 0, count < 200_000, b.has(base, count * 4) else { return nil }

            var result: [String] = []
            result.reserveCapacity(count)
            for i in 0..<count {
                let relative = Int(b.u32(base + i * 4))
                var p = offset + stringsStart + relative
                guard b.has(p, 2) else { result.append(""); continue }
                if utf8 {
                    var charLen = Int(b.u8(p)); p += 1
                    if charLen & 0x80 != 0 {
                        guard b.has(p, 1) else { result.append(""); continue }
                        charLen = ((charLen & 0x7F) << 8) | Int(b.u8(p)); p += 1
                    }
                    var byteLen = Int(b.u8(p)); p += 1
                    if byteLen & 0x80 != 0 {
                        guard b.has(p, 1) else { result.append(""); continue }
                        byteLen = ((byteLen & 0x7F) << 8) | Int(b.u8(p)); p += 1
                    }
                    guard b.has(p, byteLen) else { result.append(""); continue }
                    result.append(String(bytes: Array(b.bytes[p..<(p + byteLen)]), encoding: .utf8) ?? "")
                } else {
                    let len = Int(b.u16(p)); p += 2
                    guard b.has(p, len * 2) else { result.append(""); continue }
                    var units: [UInt16] = []
                    units.reserveCapacity(len)
                    for j in 0..<len { units.append(b.u16(p + j * 2)) }
                    result.append(String(decoding: units, as: UTF16.self))
                }
            }
            strings = result
            _ = chunkSize
        }
    }

    // MARK: - ZIP

    private struct ZipEntry {
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private static func zipEntries(_ b: Bytes) -> [String: ZipEntry] {
        guard b.count >= 22 else { return [:] }
        var eocd = b.count - 22
        let lowerBound = max(0, b.count - 66_000)
        while eocd >= lowerBound && b.u32(eocd) != 0x06054b50 { eocd -= 1 }
        guard eocd >= lowerBound else { return [:] }

        let count = Int(b.u16(eocd + 10))
        var offset = Int(b.u32(eocd + 16))
        var entries: [String: ZipEntry] = [:]
        for _ in 0..<count {
            guard b.has(offset, 46), b.u32(offset) == 0x02014b50 else { break }
            let method = b.u16(offset + 10)
            let csize = Int(b.u32(offset + 20))
            let usize = Int(b.u32(offset + 24))
            let nameLen = Int(b.u16(offset + 28))
            let extraLen = Int(b.u16(offset + 30))
            let commentLen = Int(b.u16(offset + 32))
            let local = Int(b.u32(offset + 42))
            let nameStart = offset + 46
            guard b.has(nameStart, nameLen) else { break }
            let nameBytes = Array(b.bytes[nameStart..<(nameStart + nameLen)])
            let name = String(decoding: nameBytes, as: UTF8.self)
            entries[name] = ZipEntry(method: method, compressedSize: csize,
                                     uncompressedSize: usize, localOffset: local)
            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func extract(_ name: String, from b: Bytes, entries: [String: ZipEntry]) -> Data? {
        guard let entry = entries[name], b.has(entry.localOffset, 30),
              b.u32(entry.localOffset) == 0x04034b50 else { return nil }
        let nameLen = Int(b.u16(entry.localOffset + 26))
        let extraLen = Int(b.u16(entry.localOffset + 28))
        let start = entry.localOffset + 30 + nameLen + extraLen
        guard b.has(start, entry.compressedSize) else { return nil }
        let raw = Data(b.bytes[start..<(start + entry.compressedSize)])
        if entry.method == 0 { return raw }
        if entry.method == 8 { return inflate(raw, expected: entry.uncompressedSize) }
        return nil
    }

    private static func inflate(_ data: Data, expected: Int) -> Data? {
        guard expected > 0, !data.isEmpty else { return nil }
        var output = [UInt8](repeating: 0, count: expected)
        var producedOut = 0
        var succeeded = false

        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                var stream = compression_stream(
                    dst_ptr: dstBase.assumingMemoryBound(to: UInt8.self),
                    dst_size: expected,
                    src_ptr: srcBase.assumingMemoryBound(to: UInt8.self),
                    src_size: data.count,
                    state: nil
                )
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                        != COMPRESSION_STATUS_ERROR else { return }
                defer { compression_stream_destroy(&stream) }
                // 关键：compression_stream_init 会重置流字段，src/dst 必须在 init 之后再设置。
                // 先填字段再 init 会导致解压恒失败（应用名/图标/manifest 全部解不出的根因）。
                stream.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
                stream.src_size = data.count
                stream.dst_ptr = dstBase.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = expected
                let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                var status = compression_stream_process(&stream, flags)
                var produced = expected - stream.dst_size
                // 大数据需要多轮 process（包括输入耗尽后的 flush 轮，FINALIZE 要再调一次
                // 才返回 END），直到 END 或输出写满；dst 写满后继续调用会 ERROR 自动退出
                while status == COMPRESSION_STATUS_OK && produced < expected {
                    status = compression_stream_process(&stream, flags)
                    produced = expected - stream.dst_size
                }
                producedOut = produced
                succeeded = produced > 0 &&
                    (status == COMPRESSION_STATUS_END || produced >= expected)
            }
        }
        guard succeeded else { return nil }
        return Data(output[0..<producedOut])
    }

    // MARK: - Byte helper

    private struct Bytes {
        let bytes: [UInt8]

        var count: Int { bytes.count }

        init(_ data: Data) { bytes = [UInt8](data) }

        func has(_ offset: Int, _ length: Int) -> Bool {
            offset >= 0 && length >= 0 && offset <= bytes.count && length <= bytes.count - offset
        }

        func u8(_ offset: Int) -> UInt8 {
            guard has(offset, 1) else { return 0 }
            return bytes[offset]
        }

        func u16(_ offset: Int) -> UInt16 {
            guard has(offset, 2) else { return 0 }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        func u32(_ offset: Int) -> UInt32 {
            guard has(offset, 4) else { return 0 }
            return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

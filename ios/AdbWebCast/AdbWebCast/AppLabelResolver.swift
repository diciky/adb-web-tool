import Foundation
import Compression

/// 从已安装 APK 解析应用显示名（优先中文）与启动图标，不依赖 Mac 侧 aapt。
///
/// - 一次 pull 同时拿到 `AndroidManifest.xml` / `resources.arsc` / 图标资源；
/// - 二进制 XML 取 `<application android:label>` 与 `android:icon`；
/// - 资源表按 zh-CN > zh > 默认 > 其他语言 解析字符串；
/// - 图标从 `res/<type>-<density>/<name>.png|webp` 提取；
/// - 结果本地缓存（名称 UserDefaults，图标 Caches 目录），避免重复拉包。
enum AppLabelResolver {

    // MARK: - Public

    struct AssetResult {
        let label: String?
        let iconData: Data?
    }

    /// 解析单个应用。返回的名称为 nil 时调用方回退包名。
    static func assets(for pkg: String, apkPath: String, client: AdbClient) -> AssetResult {
        let labelCached = cachedLabel(pkg: pkg, apkPath: apkPath)
        let iconCached = cachedIcon(pkg: pkg)
        if labelCached != nil, iconCached != nil {
            return AssetResult(label: labelCached, iconData: iconCached)
        }
        guard let result = resolve(pkg: pkg, apkPath: apkPath, client: client) else {
            return AssetResult(label: labelCached, iconData: iconCached)
        }
        var finalLabel = labelCached
        if finalLabel == nil, let label = result.label {
            finalLabel = label
            cacheLabel(label, pkg: pkg, apkPath: apkPath)
        }
        var finalIcon = iconCached
        if finalIcon == nil, let icon = result.iconData {
            finalIcon = icon
            cacheIcon(icon, pkg: pkg)
        }
        return AssetResult(label: finalLabel, iconData: finalIcon)
    }

    /// 兼容旧调用：只取名称。
    static func label(for pkg: String, apkPath: String, client: AdbClient) -> String? {
        assets(for: pkg, apkPath: apkPath, client: client).label
    }

    /// 只查缓存，不触发网络/IO。用于首屏立刻显示名称。
    static func cachedLabel(pkg: String, apkPath: String) -> String? {
        cache[cacheKey(pkg: pkg, apkPath: apkPath)]
    }

    /// 只查图标缓存。
    static func cachedIcon(pkg: String) -> Data? {
        guard let url = iconURL(pkg: pkg) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Cache

    private static let cacheDefaultsKey = "adbweb.app.labels.v1"
    private static var cache: [String: String] = loadCache()

    private static func cacheKey(pkg: String, apkPath: String) -> String {
        "\(pkg)|\(apkPath)"
    }

    private static func loadCache() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cacheDefaultsKey) as? [String: String] ?? [:]
    }

    private static func saveCache() {
        let snapshot = cache
        DispatchQueue.global(qos: .utility).async {
            UserDefaults.standard.set(snapshot, forKey: cacheDefaultsKey)
        }
    }

    private static func cacheLabel(_ label: String, pkg: String, apkPath: String) {
        cache[cacheKey(pkg: pkg, apkPath: apkPath)] = label
        saveCache()
    }

    private static func iconDirectory() -> URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let dir = base.appendingPathComponent("adbweb-app-icons", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func iconURL(pkg: String) -> URL? {
        guard let dir = iconDirectory() else { return nil }
        let safe = pkg.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).icon")
    }

    private static func cacheIcon(_ data: Data, pkg: String) {
        guard let url = iconURL(pkg: pkg) else { return }
        try? data.write(to: url, options: .atomic)
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
        guard !path.isEmpty else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset_\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try client.pull(remotePath: path, to: tmp, progress: { _ in })
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
            // 超大游戏包跳过，避免手机内存吃满；这类包回退包名与占位图标。
            guard size > 0, size <= 160 * 1024 * 1024 else { return nil }
            guard let data = try? Data(contentsOf: tmp, options: .mappedIfSafe) else { return nil }
            let bytes = Bytes(data)
            let entries = zipEntries(bytes)
            guard let manifestData = extract("AndroidManifest.xml", from: bytes, entries: entries),
                  let info = manifestInfo(in: manifestData) else { return nil }

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
            return AssetResult(label: label, iconData: icon)
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

    private static func findIcon(iconId: UInt32?, bytes: Bytes,
                                 entries: [String: ZipEntry]) -> Data? {
        var candidates: [String] = []
        let densities = ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi", "ldpi", "anydpi", "nodpi", ""]

        if let iconId = iconId,
           let name = entryName(for: iconId, in: Data(bytes.bytes)),
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
            }
        }
        // 兜底：常见启动图标文件名。
        for key in ["ic_launcher", "app_icon", "launcher_icon", "icon"] {
            for type in ["mipmap", "drawable"] {
                for density in densities {
                    let dir = density.isEmpty ? "res/\(type)" : "res/\(type)-\(density)"
                    candidates.append("\(dir)/\(key).png")
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
        if let iconId = iconId,
           let name = entryName(for: iconId, in: Data(bytes.bytes)),
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
        var produced = 0
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
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                produced = expected - stream.dst_size
                succeeded = (status == COMPRESSION_STATUS_END || status == COMPRESSION_STATUS_OK) && produced > 0
                compression_stream_destroy(&stream)
            }
        }
        guard succeeded else { return nil }
        return Data(output[0..<produced])
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

import Foundation
import Compression

/// 从已安装 APK 里解析应用显示名（优先中文），不依赖 Mac 侧 aapt。
///
/// - 只读取 APK 中的 `AndroidManifest.xml` 与 `resources.arsc`；
/// - 支持 stored / deflate 两种 ZIP 压缩方式；
/// - 二进制 XML 取 `<application android:label>`；
/// - 资源表按 zh-CN > zh > 默认 > 其他语言 的优先级解析字符串；
/// - 解析结果缓存在 UserDefaults，避免重复拉包。
enum AppLabelResolver {

    // MARK: - Public

    /// 读取缓存；没有缓存时实时解析。失败返回 nil，调用方回退包名。
    static func label(for pkg: String, apkPath: String, client: AdbClient) -> String? {
        if let cached = cache[cacheKey(pkg: pkg, apkPath: apkPath)] { return cached }
        guard let name = resolve(pkg: pkg, apkPath: apkPath, client: client) else { return nil }
        cache[cacheKey(pkg: pkg, apkPath: apkPath)] = name
        saveCache()
        return name
    }

    /// 只查缓存，不触发网络/IO。用于首屏立刻显示名称。
    static func cachedLabel(pkg: String, apkPath: String) -> String? {
        cache[cacheKey(pkg: pkg, apkPath: apkPath)]
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

    // MARK: - Resolve

    private static func resolve(pkg: String, apkPath: String, client: AdbClient) -> String? {
        guard !apkPath.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("label_\(UUID().uuidString).apk")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try client.pull(remotePath: apkPath, to: tmp, progress: { _ in })
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.intValue ?? 0
            // 只解析小包，避免超大游戏包把手机内存吃满；超大包回退包名。
            guard size > 0, size <= 96 * 1024 * 1024 else { return nil }
            guard let data = try? Data(contentsOf: tmp, options: .mappedIfSafe) else { return nil }
            let bytes = Bytes(data)
            let entries = zipEntries(bytes)
            guard let manifestData = extract("AndroidManifest.xml", from: bytes, entries: entries),
                  let manifestLabel = findLabel(in: manifestData) else { return nil }

            switch manifestLabel {
            case .string(let value):
                return cleanLabel(value)
            case .reference(let id):
                guard let arsc = extract("resources.arsc", from: bytes, entries: entries) else { return nil }
                return resolveReference(id, in: arsc).flatMap(cleanLabel)
            }
        } catch {
            AdbLog.log("解析应用名失败 \(pkg): \(error.localizedDescription)", level: "W")
            return nil
        }
    }

    private static func cleanLabel(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 部分旧工具链会把 UTF-16LE 标签按单字节解码，字符之间夹 0x00。
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

    private static func findLabel(in xml: Data) -> ManifestLabel? {
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
                   let label = applicationLabel(in: b, at: offset, headerSize: headerSize, pool: pool) {
                    return label
                }
            }
            offset += chunkSize
        }
        return nil
    }

    private static func applicationLabel(in b: Bytes, at offset: Int, headerSize: Int,
                                         pool: StringPool) -> ManifestLabel? {
        guard b.has(offset + 24, 8) else { return nil }
        let nameIndex = Int(b.u32(offset + 20))
        guard pool.strings.indices.contains(nameIndex), pool.strings[nameIndex] == "application" else { return nil }

        let attrStart = Int(b.u16(offset + 24))
        let attrSize = Int(b.u16(offset + 26))
        let attrCount = Int(b.u16(offset + 28))
        guard attrSize >= 20 else { return nil }
        var p = offset + headerSize + attrStart
        for _ in 0..<attrCount {
            guard b.has(p, 20) else { return nil }
            let nameIndex = Int(b.u32(p + 4))
            let rawValue = b.u32(p + 8)
            let dataType = b.u8(p + 15)
            let data = b.u32(p + 16)
            let attrName = pool.strings.indices.contains(nameIndex) ? pool.strings[nameIndex] : ""
            if attrName == "label" {
                if dataType == 0x01 { return .reference(data) }   // TYPE_REFERENCE
                if dataType == 0x03, pool.strings.indices.contains(Int(data)) {
                    return .string(pool.strings[Int(data)])       // TYPE_STRING
                }
                if rawValue != 0xFFFFFFFF, pool.strings.indices.contains(Int(rawValue)) {
                    return .string(pool.strings[Int(rawValue)])
                }
            }
            p += attrSize
        }
        return nil
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
        guard flags & 0x0001 == 0 else { return nil }  // complex entry 不直接含字符串
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

    // MARK: - String pool

    private struct StringPool {
        let strings: [String]

        init?(_ b: Bytes, offset: Int, chunkSize: Int) {
            guard b.has(offset + 20, 4) else { return nil }
            let count = Int(b.u32(offset + 8))
            let flags = b.u32(offset + 16)
            let stringsStart = Int(b.u32(offset + 20))
            let headerSize = max(Int(b.u16(offset + 2)), 28)
            let utf8 = (flags & 0x100) != 0
            let base = offset + headerSize
            guard b.has(base, count * 4) else { return nil }

            var result: [String] = []
            result.reserveCapacity(count)
            for i in 0..<count {
                let relative = Int(b.u32(base + i * 4))
                var p = offset + stringsStart + relative
                guard b.has(p, 2) else { result.append(""); continue }
                if utf8 {
                    p += 2  // UTF-16 长度，字节长度单独编码
                    guard b.has(p, 1) else { result.append(""); continue }
                    var len = Int(b.u8(p)); p += 1
                    if len & 0x80 != 0 {
                        guard b.has(p, 1) else { result.append(""); continue }
                        len = ((len & 0x7F) << 8) | Int(b.u8(p)); p += 1
                    }
                    guard b.has(p, len) else { result.append(""); continue }
                    result.append(String(bytes: Array(b.bytes[p..<(p + len)]), encoding: .utf8) ?? "")
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
            let nextOffset = offset + 46 + nameLen + extraLen + commentLen
            offset = nextOffset
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
                var stream = compression_stream()
                stream.src_ptr = UnsafeMutablePointer(mutating: srcBase.assumingMemoryBound(to: UInt8.self))
                stream.src_size = data.count
                stream.dst_ptr = dstBase.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = expected
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

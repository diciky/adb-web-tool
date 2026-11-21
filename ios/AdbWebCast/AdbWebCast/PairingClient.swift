import Foundation
import Network

// MARK: - ADB 无线调试配对客户端（Android 11+ 配对码）
// 复刻 AOSP pairing_connection.cpp 的完整流程：
//  TLS 1.3（客户端证书）→ exporter("adb-label\0") → 密码=配对码+exporter
//  → SPAKE2 消息交换 → AES-128-GCM 加密交换 PeerInfo（上交公钥 / 收回设备 GUID）

enum PairingError: Error, LocalizedError {
    case tlsHandshake(String)
    case exporterFailed
    case protocolError(String)
    case badCode

    var errorDescription: String? {
        switch self {
        case .tlsHandshake(let s): return "TLS 连接失败：\(s)"
        case .exporterFailed: return "无法导出 TLS 密钥材料"
        case .protocolError(let s): return s
        case .badCode: return "配对码无效"
        }
    }
}

final class PairingClient {

    /// 发起配对。返回设备的 GUID。
    /// host/port 来自设备的「使用配对码配对设备」弹窗（IP 与端口）或 mDNS 发现。
    static func pair(host: String, port: UInt16, code: String,
                     progress: @escaping (String) -> Void = { _ in }) throws -> String {
        let digits = code.trimmingCharacters(in: .whitespaces)
        guard digits.count >= 6, digits.allSatisfy({ $0.isNumber }) else {
            throw PairingError.badCode
        }
        progress("连接配对服务 \(host):\(port)…")
        let transport = AdbTLSTransport()
        transport.setReadTimeout(15)
        do {
            try transport.connect(host: host, port: port, timeout: 8)
        } catch {
            throw PairingError.tlsHandshake(error.localizedDescription)
        }
        defer { transport.closeSocket() }

        // 1. 导出 TLS 密钥材料（label 与 AOSP 的 kExportedKeyLabel 完全一致，含结尾 '\0' 共 10 字节）
        progress("TLS 已建立，导出密钥材料…")
        var label = Array("adb-label".utf8)
        label.append(0)
        guard let exported = transport.exportKeyingMaterial(length: 64, label: label),
              exported.count == 64 else {
            throw PairingError.exporterFailed
        }

        // 2. SPAKE2：密码 = 配对码 + exporter
        var password = Array(digits.utf8)
        password.append(contentsOf: exported)
        let spake = Spake2(adbClient: true)
        let myMsg = try spake.generateMsg(password: password)
        AdbLog.log("配对 SPAKE2 消息已生成（\(myMsg.count)B）")

        // 3. 交换 SPAKE2 消息（PairingPacketHeader：version u8 + type u8 + payload u32 BE）
        progress("交换 SPAKE2 消息…")
        try writePacket(transport, type: 0, payload: Data(myMsg))   // SPAKE2_MSG = 0
        let theirPacket = try readPacket(transport, expectType: 0)
        AdbLog.log("收到设备 SPAKE2 消息（\(theirPacket.count)B）")
        let keyMaterial = try spake.processMsg(Array(theirPacket))
        let cipher = PairingCipher(keyMaterial: keyMaterial)

        // 4. 加密交换 PeerInfo：上交 ADB 公钥（type=ADB_RSA_PUB_KEY=0），收回设备 GUID
        progress("上交公钥，等待设备确认…")
        var peerInfo = Data(repeating: 0, count: 8192)
        let pub = AdbIdentity.peerPublicKeyData()
        peerInfo[0] = 0
        peerInfo.replaceSubrange(1..<(1 + pub.count), with: pub)
        let encrypted = try cipher.encrypt(peerInfo)
        try writePacket(transport, type: 1, payload: encrypted)     // PEER_INFO = 1

        let theirs = try readPacket(transport, expectType: 1)
        let decrypted: Data
        do {
            decrypted = try cipher.decrypt(theirs)
        } catch {
            throw PairingError.protocolError("PeerInfo 解密失败（配对码很可能不对）")
        }
        guard decrypted.count == 8192 else {
            throw PairingError.protocolError("PeerInfo 长度异常：\(decrypted.count)")
        }
        let theirType = decrypted[decrypted.startIndex]
        let dataBytes = Array(decrypted.dropFirst())
        if theirType == 1 {   // ADB_DEVICE_GUID
            let guidBytes = dataBytes.prefix(while: { $0 != 0 })
            let guid = String(bytes: guidBytes, encoding: .utf8) ?? ""
            progress("配对成功 guid=\(guid)")
            AdbLog.log("配对成功，设备 GUID=\(guid)")
            return guid
        }
        throw PairingError.protocolError("设备返回未知 PeerInfo 类型：\(theirType)")
    }

    // MARK: - PairingPacketHeader 读写
    private static func writePacket(_ transport: AdbTransport, type: UInt8, payload: Data) throws {
        var header = Data()
        header.append(1)                    // version
        header.append(type)
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        try transport.writeAll(header)
        try transport.writeAll(payload)
    }

    private static func readPacket(_ transport: AdbTransport, expectType: UInt8) throws -> Data {
        let header = try transport.receiveExact(6)
        let version = header[header.startIndex]
        let type = header[header.startIndex + 1]
        let sizeLE = Array(header[(header.startIndex + 2)..<(header.startIndex + 6)])
        // htonl → 大端
        var size: UInt32 = 0
        for b in sizeLE { size = (size << 8) | UInt32(b) }
        guard version == 1 else {
            throw PairingError.protocolError("PairingPacketHeader 版本不支持：\(version)")
        }
        guard type == expectType else {
            throw PairingError.protocolError("收到非预期包类型 \(type)（期望 \(expectType)）")
        }
        guard size > 0 && size <= 16384 else {
            throw PairingError.protocolError("包大小异常：\(size)")
        }
        return try transport.receiveExact(Int(size))
    }
}

// MARK: - mDNS 配对服务发现（设备进入「配对码配对」时广播 _adb-tls-pairing._tcp）
final class AdbPairingBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private let onFound: (String, UInt16) -> Void
    private var stopped = false

    init(onFound: @escaping (String, UInt16) -> Void) {
        self.onFound = onFound
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "local.")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeAll { $0 === sender } }
        guard !stopped, sender.port > 0,
              let ip = sender.addresses?.compactMap(Self.ipv4(from:)).first else { return }
        onFound(ip, UInt16(clamping: sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }

    private static func ipv4(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            var addr = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
            guard Int32(addr.sin_family) == AF_INET else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            guard result == 0 else { return nil }
            return String(cString: host)
        }
    }
}

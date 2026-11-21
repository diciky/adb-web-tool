import Foundation
import Security

#if canImport(UIKit)
private let kAdbKeychainAccessible = kSecAttrAccessibleAfterFirstUnlock
#else
private let kAdbKeychainAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

// MARK: - ADB TLS 客户端身份：内置 RSA 密钥 → 自签名 X.509 证书 → SecIdentity
// Android 11+ 无线调试的 adbd 要求 TLS 客户端证书，且证书公钥必须在授权列表中
//（配对时 PeerInfo 里上交的就是同一把 RSA 公钥）。iOS 无法用系统 API 生成证书，
// 这里手工编码 DER 构建 v3 自签名证书，并用 Security 框架做 RSA-SHA256 签名。

enum AdbIdentityError: Error, LocalizedError {
    case keyMissing
    case derEncode(String)
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .keyMissing: return "内置 ADB 密钥不可用"
        case .derEncode(let s): return "证书编码失败：\(s)"
        case .keychain(let s): return "证书写入钥匙串失败：\(s)"
        }
    }
}

final class AdbIdentity {
    static let shared = AdbIdentity()
    private var cached: SecIdentity?

    /// PKCS#1 RSAPrivateKey DER
    private var privateDER: Data? { Data(base64Encoded: ADB_PRIV_DER_B64) }

    /// RSA 私钥 SecKey（复用 AdbKeys 的导入逻辑）
    private func privateKey() throws -> SecKey {
        guard let key = AdbKeys.privateKey else { throw AdbIdentityError.keyMissing }
        return key
    }

    /// TLS 握手用的客户端身份（证书 + 私钥），进程内缓存
    func secIdentity() -> SecIdentity? {
        if let c = cached { return c }
        do {
            let id = try createIdentity()
            cached = id
            return id
        } catch {
            AdbLog.log("TLS 身份创建失败：\(error.localizedDescription)", level: "E")
            return nil
        }
    }

    // MARK: - DER 编码原语
    private func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [tag]
        if content.count < 128 {
            out.append(UInt8(content.count))
        } else {
            var len = content.count
            var lenBytes: [UInt8] = []
            while len > 0 { lenBytes.insert(UInt8(len & 0xff), at: 0); len >>= 8 }
            out.append(UInt8(0x80 | lenBytes.count))
            out.append(contentsOf: lenBytes)
        }
        out.append(contentsOf: content)
        return out
    }

    private func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(0x30, parts.flatMap { $0 }) }
    private func setOf(_ parts: [UInt8]...) -> [UInt8] { tlv(0x31, parts.flatMap { $0 }) }
    private func integer(_ bytes: [UInt8]) -> [UInt8] {
        // 去掉前导 0 的负号问题：最高位为 1 时补 0x00
        var b = bytes
        while b.count > 1 && b[0] == 0 && (b[1] & 0x80) == 0 { b.removeFirst() }
        if let f = b.first, f & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }
    private func integerFromLE(_ le: [UInt8]) -> [UInt8] {
        var be = Array(le.reversed())
        while be.count > 1 && be[0] == 0 { be.removeFirst() }
        return integer(be)
    }
    private func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }
    private func utf8String(_ s: String) -> [UInt8] { tlv(0x0c, Array(s.utf8)) }
    private func utcTime(_ s: String) -> [UInt8] { tlv(0x17, Array(s.utf8)) }
    private func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }
    private func null() -> [UInt8] { [0x05, 0x00] }

    private let oidCN: [UInt8] = [0x55, 0x04, 0x03]                     // 2.5.4.3
    private let oidRSAEncryption: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
    private let oidSHA256withRSA: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]

    // MARK: - 从 PKCS#1 私钥 DER 中解析出 n、e（极简 ASN.1 读取）
    private struct ASN1Reader {
        let bytes: [UInt8]
        var pos = 0
        mutating func readTLV() -> (tag: UInt8, content: ArraySlice<UInt8>)? {
            guard pos < bytes.count else { return nil }
            let tag = bytes[pos]; pos += 1
            var len = Int(bytes[pos]); pos += 1
            if len & 0x80 != 0 {
                let n = len & 0x7f
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(bytes[pos]); pos += 1 }
            }
            let content = bytes[pos..<(pos + len)]
            pos += len
            return (tag, content)
        }
    }

    /// 从 PKCS#1 RSAPrivateKey DER 提取 (n 大端, e 大端)
    private func parseRSAPrivate(der: Data) throws -> (n: [UInt8], e: [UInt8]) {
        var reader = ASN1Reader(bytes: Array(der))
        guard let outer = reader.readTLV(), outer.tag == 0x30 else {
            throw AdbIdentityError.derEncode("私钥外层结构异常")
        }
        var inner = ASN1Reader(bytes: Array(outer.content))
        guard inner.readTLV()?.tag == 0x02 else {            // version
            throw AdbIdentityError.derEncode("私钥缺少 version")
        }
        guard let nTLV = inner.readTLV(), nTLV.tag == 0x02 else {
            throw AdbIdentityError.derEncode("私钥缺少 modulus")
        }
        guard let eTLV = inner.readTLV(), eTLV.tag == 0x02 else {
            throw AdbIdentityError.derEncode("私钥缺少 exponent")
        }
        return (Array(nTLV.content), Array(eTLV.content))
    }

    // MARK: - 生成自签名证书 DER
    func buildCertificateDER() throws -> Data {
        let key = try privateKey()
        guard let privDER = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let n = try? parseRSAPrivate(der: privDER) else {
            throw AdbIdentityError.derEncode("私钥解析失败")
        }

        // SPKI
        let spki = sequence(
            sequence(oid(oidRSAEncryption), null()),
            bitString(sequence(integer(n.n), integer(n.e)))
        )

        // 序列号（正数，16 字节）
        var serialLE = [UInt8](repeating: 0, count: 16)
        serialLE.withUnsafeMutableBytes { buf in
            arc4random_buf(buf.baseAddress!, 16)
        }
        serialLE[15] &= 0x7f   // 保证为正

        // 名称：CN=adb
        let name = sequence(setOf(sequence(oid(oidCN), utf8String("adb"))))

        // X.509 TbsCertificate 字段顺序（RFC 5280）：
        // version, serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
        let tbs = sequence(
            tlv(0xa0, integer([2])),                     // [0] EXPLICIT version=2(v3)
            integerFromLE(serialLE),
            sequence(oid(oidSHA256withRSA), null()),
            name,
            sequence(utcTime("250101000000Z"), utcTime("491231235959Z")),
            name,
            spki
        )

        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                              Data(tbs) as CFData, &error) as Data? else {
            let msg = (error?.takeRetainedValue().localizedDescription) ?? "签名失败"
            throw AdbIdentityError.derEncode(msg)
        }
        let cert = sequence(
            tbs,
            sequence(oid(oidSHA256withRSA), null()),
            bitString(Array(sig))
        )
        return Data(cert)
    }

    // MARK: - 写入钥匙串并创建 SecIdentity
    private func createIdentity() throws -> SecIdentity {
        let certDER = try buildCertificateDER()
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw AdbIdentityError.derEncode("生成的证书无法解析")
        }
        let label = "adbwebcast.tls.identity"

        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueData as String: certDER,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kAdbKeychainAccessible,
        ]
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
        let certStatus = SecItemAdd(certAdd as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw AdbIdentityError.keychain("cert: \(certStatus)")
        }

        let keyAdd: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecValueData as String: privateDER ?? Data(),
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kAdbKeychainAccessible,
        ]
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label] as CFDictionary)
        let keyStatus = SecItemAdd(keyAdd as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw AdbIdentityError.keychain("key: \(keyStatus)")
        }

        // SecIdentity 构建：macOS 用 SecIdentityCreateWithCertificate；
        // iOS 无此 API，标准做法是从钥匙串按 kSecClassIdentity 查询（证书+私钥须同名关联）
        #if os(macOS)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard status == errSecSuccess, let id = identity else {
            throw AdbIdentityError.keychain("identity: \(status)")
        }
        return id
        #else
        let idQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
        ]
        var ref: CFTypeRef?
        let idStatus = SecItemCopyMatching(idQuery as CFDictionary, &ref)
        guard idStatus == errSecSuccess, let id = ref as? SecIdentity else {
            throw AdbIdentityError.keychain("identity: \(idStatus)")
        }
        return id
        #endif
    }

    // MARK: - 配对 PeerInfo 里上交的公钥串（与 AUTH 公钥同源）
    /// 设备端把它作为一行 adb_keys 记录保存："<base64> <name>\0"
    static func peerPublicKeyData() -> Data {
        var payload = Data(ADB_PUB_B64.utf8)
        payload.append(Data(" adbwebcast".utf8))
        payload.append(0)
        return payload
    }
}

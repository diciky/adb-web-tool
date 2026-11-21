import Foundation
import CryptoKit
import Security

// MARK: - ADB 无线调试配对协议（Android 11+）
// 逐行复刻 AOSP adb 的 pairing_auth（BoringSSL spake25519）+ pairing_connection +
// aes_128_gcm 三层协议。关键协议常量（与 AOSP 源码一一对应）：
//  - SPAKE2 在 Edwards25519 上实现，客户端=alice（掩码点 M）、设备端=bob（掩码点 N）
//  - 名字串含 '\0'：客户端 "adb pair client\0"、服务端 "adb pair server\0"（各 16 字节）
//  - 密码 = 6 位配对码 ASCII + TLS exporter 64 字节（label "adb-label\0"）
//  - key = SHA-512(带 8 字节 LE 长度前缀的: 名字A、名字B、消息A、消息B、DH值、密码SHA-512)
//  - PeerInfo 用 AES-128-GCM 加密：HKDF-SHA256(key, info="adb pairing_auth aes-128-gcm key")→16B
//  - nonce = 12 字节：前 8 字节小端序计数器（每方向独立，从 0 开始），后 4 字节 0

enum PairingCryptoError: Error, LocalizedError {
    case pointDecode
    case badMessage

    var errorDescription: String? {
        switch self {
        case .pointDecode: return "SPAKE2 消息不是合法的曲线点"
        case .badMessage: return "SPAKE2 消息长度错误"
        }
    }
}

// MARK: - 大整数（小端字节数组）
enum BigLE {
    static func trim(_ a: [UInt8]) -> [UInt8] {
        var r = a
        while r.count > 1 && r.last == 0 { r.removeLast() }
        if r.isEmpty { r = [0] }
        return r
    }

    static func cmp(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = max(a.count, b.count)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// a + b（进位自然扩展）
    static func add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(a.count, b.count) + 1)
        var carry = 0
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? Int(a[i]) : 0
            let y = i < b.count ? Int(b[i]) : 0
            let s = x + y + carry
            out[i] = UInt8(s & 0xff)
            carry = s >> 8
        }
        out[out.count - 1] = UInt8(carry)
        return trim(out)
    }

    /// a - b，要求 a >= b（结果截去高位 0）
    static func sub(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = a
        var borrow = 0
        for i in 0..<out.count {
            let y = i < b.count ? Int(b[i]) : 0
            var s = Int(out[i]) - y - borrow
            if s < 0 { s += 256; borrow = 1 } else { borrow = 0 }
            out[i] = UInt8(s)
        }
        return trim(out)
    }

    static func mul(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        if a == [0] || b == [0] { return [0] }
        var out = [UInt8](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            var carry = 0
            let ai = Int(a[i])
            if ai == 0 { continue }
            for j in 0..<b.count {
                let t = ai * Int(b[j]) + Int(out[i + j]) + carry
                out[i + j] = UInt8(t & 0xff)
                carry = t >> 8
            }
            var k = i + b.count
            while carry > 0 {
                let t = Int(out[k]) + carry
                out[k] = UInt8(t & 0xff)
                carry = t >> 8
                k += 1
            }
        }
        return trim(out)
    }

    /// 左移 n 位
    static func shl(_ a: [UInt8], _ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.count + n / 8 + 1)
        for i in 0..<a.count {
            let v = Int(a[i]) << (n % 8)
            out[i + n / 8] |= UInt8(v & 0xff)
            out[i + n / 8 + 1] |= UInt8((v >> 8) & 0xff)
        }
        return trim(out)
    }

    /// 位值（第 i 位）
    static func bit(_ a: [UInt8], _ i: Int) -> Int {
        let byte = i / 8
        guard byte < a.count else { return 0 }
        return (Int(a[byte]) >> (i % 8)) & 1
    }

    /// 按位取模（长除法，用于标量归约；输入输出小端）
    static func mod(_ value: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        let bits = value.count * 8
        var r: [UInt8] = [0]
        guard modulus != [0] else { return value }
        var started = false
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if !started && bit(value, i) == 0 { continue }
            started = true
            r = shl(r, 1)
            if bit(value, i) == 1 { r[0] |= 1 }   // 小端：bit0 在第 0 字节
            if cmp(r, modulus) >= 0 { r = sub(r, modulus) }
        }
        return trim(r)
    }

    static func powMod(_ base: [UInt8], _ exp: [UInt8], _ modulus: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [1]
        let b = mod(base, modulus)
        let bits = exp.count * 8
        var started = false
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if !started && bit(exp, i) == 0 { continue }
            started = true
            result = mod(mul(result, result), modulus)
            if bit(exp, i) == 1 { result = mod(mul(result, b), modulus) }
        }
        return result
    }
}

// MARK: - 有限域 GF(2^255 - 19)
struct Fp: Equatable {
    static let pLE: [UInt8] = [0xed] + [UInt8](repeating: 0xff, count: 30) + [0x7f] // 2^255-19
    var v: [UInt8]   // 32 字节小端，恒 < p

    static func == (l: Fp, r: Fp) -> Bool { l.v == r.v }

    init(_ bytes: [UInt8]) {
        var b = BigLE.mod(bytes, Self.pLE)
        if b.count < 32 { b.append(contentsOf: [UInt8](repeating: 0, count: 32 - b.count)) }
        v = Array(b.prefix(32))
    }

    static let zero = Fp([0])
    static let one = Fp([1])

    func add(_ o: Fp) -> Fp { Fp(BigLE.add(v, o.v)) }
    func sub(_ o: Fp) -> Fp {
        if BigLE.cmp(v, o.v) >= 0 { return Fp(BigLE.sub(v, o.v)) }
        // v - o ≡ p - (o - v) (mod p)，v/o 均 < p
        return Fp(BigLE.sub(Self.pLE, BigLE.sub(o.v, v)))
    }
    func neg() -> Fp {
        if v == [0] { return self }
        return Fp(BigLE.sub(Self.pLE, v))
    }
    func mul(_ o: Fp) -> Fp { Fp(BigLE.mul(v, o.v)) }
    func square() -> Fp { mul(self) }
    func inv() -> Fp { Fp(BigLE.powMod(v, BigLE.sub(Self.pLE, [2]), Self.pLE)) }
    func pow(_ e: [UInt8]) -> Fp { Fp(BigLE.powMod(v, e, Self.pLE)) }

    /// 小整数值辅助
    init(_ n: Int) {
        var b: [UInt8] = [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)]
        if b.count < 32 { b.append(contentsOf: [UInt8](repeating: 0, count: 32 - b.count)) }
        v = Array(b.prefix(32))
    }
}

// MARK: - Edwards25519 点（扩展齐次坐标 X:Y:Z:T）
struct EdPoint {
    var x, y, z, t: Fp

    static let d = Fp(121666).inv().mul(Fp(121665)).neg()   // d = -121665/121666
    /// 基点 G 的 32 字节编码（ed25519 标准）
    static let gEncoded: [UInt8] = [0x58] + [UInt8](repeating: 0x66, count: 31)
    static let identity = EdPoint(x: .zero, y: .one, z: .one, t: .zero)

    static func base() -> EdPoint { decode(gEncoded)! }

    /// 从 32 字节编码还原点（vartime，含在曲线上校验）
    static func decode(_ bytes: [UInt8]) -> EdPoint? {
        guard bytes.count == 32 else { return nil }
        var yBytes = bytes
        let sign = (yBytes[31] >> 7) & 1
        yBytes[31] &= 0x7f
        let y = Fp(yBytes)
        let yy = y.square()
        let den = d.mul(yy).add(.one)
        if den.v == [0] { return nil }           // 小阶点：d·y²+1 = 0
        let num = yy.sub(.one)
        // x² = num/den
        let x2 = num.mul(den.inv())
        // 开平方：x = x2^((p+3)/8) = x2^(2^252-2)，必要时乘 sqrt(-1)
        var x = x2.pow(Self.expP3div8())
        if x.square() != x2 {
            x = x.mul(Self.sqrtM1())
            if x.square() != x2 { return nil }
        }
        if x.v == [0] && sign == 1 { return nil }
        if Int(x.v[0]) & 1 != sign { x = x.neg() }
        return EdPoint(x: x, y: y, z: .one, t: x.mul(y))
    }

    /// (p+3)/8 = 2^252-2 的 32 字节小端（p = 2^255-19 为定值，无需通用大数除法）
    /// 二进制为位 1..251 全 1：byte0=0xfe，中间 0xff，byte31=0x0f（位 248-251）
    private static func expP3div8() -> [UInt8] {
        var r = [UInt8](repeating: 0xff, count: 32)
        r[0] = 0xfe
        r[31] = 0x0f
        return r
    }

    private static var cachedSqrtM1: Fp?
    static func sqrtM1() -> Fp {
        if let c = cachedSqrtM1 { return c }
        // sqrt(-1) = 2^((p-1)/4) mod p 的常量值（ed25519 标准，已与参考实现对拍验证）
        let v = Fp([0xb0, 0xa0, 0x0e, 0x4a, 0x27, 0x1b, 0xee, 0xc4, 0x78, 0xe4, 0x2f, 0xad,
                    0x06, 0x18, 0x43, 0x2f, 0xa7, 0xd7, 0xfb, 0x3d, 0x99, 0x00, 0x4d, 0x2b,
                    0x0b, 0xdf, 0xc1, 0x4f, 0x80, 0x24, 0x83, 0x2b])
        cachedSqrtM1 = v
        return v
    }

    func encode() -> [UInt8] {
        let zi = z.inv()
        let px = x.mul(zi)
        let py = y.mul(zi)
        var out = py.v
        out[31] |= UInt8((Int(px.v[0]) & 1) << 7)
        return out
    }

    /// 统一加法公式（add-2008-hwcd-3，与 BoringSSL ge_add 一致）
    func add(_ o: EdPoint) -> EdPoint {
        let d2 = EdPoint.d.add(EdPoint.d)
        let a = y.sub(x).mul(o.y.sub(o.x))
        let b = y.add(x).mul(o.y.add(o.x))
        let c = t.mul(d2).mul(o.t)
        let dd = z.mul(Fp(2)).mul(o.z)
        let e = b.sub(a), f = dd.sub(c), g = dd.add(c), h = b.add(a)
        return EdPoint(x: e.mul(f), y: g.mul(h), z: f.mul(g), t: e.mul(h))
    }

    func neg() -> EdPoint { EdPoint(x: x.neg(), y: y, z: z, t: t.neg()) }
    func sub(_ o: EdPoint) -> EdPoint { add(o.neg()) }

    /// 倍点公式（dbl-2008-hwcd，a=-1，与 BoringSSL ge_double 一致）
    func dbl() -> EdPoint {
        let a = x.square()
        let b = y.square()
        let c = z.square().add(z.square())
        let dneg = a.neg()
        let e = x.add(y).square().sub(a).sub(b)
        let g = dneg.add(b)          // B - A
        let f = g.sub(c)
        let h = dneg.sub(b)          // -(A + B)
        return EdPoint(x: e.mul(f), y: g.mul(h), z: f.mul(g), t: e.mul(h))
    }

    /// 标量乘（MSB→LSB double-and-add，标量小端字节数组）
    func scalarMul(_ scalarLE: [UInt8]) -> EdPoint {
        var r = EdPoint.identity
        let bits = 256
        var started = false
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if !started && BigLE.bit(scalarLE, i) == 0 { continue }
            started = true
            r = r.dbl()
            if BigLE.bit(scalarLE, i) == 1 { r = r.add(self) }
        }
        return r
    }
}

// MARK: - ed25519 标量运算
enum EdScalar {
    /// ed25519 群阶 l 的 32 字节小端
    static let orderLE: [UInt8] = {
        var o = [UInt8](repeating: 0, count: 32)
        let low: [UInt8] = [0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58,
                            0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14]
        for (i, b) in low.enumerated() { o[i] = b }
        o[31] = 0x10    // l = 2^252 + 27742…493
        return o
    }()

    /// BoringSSL x25519_sc_reduce：64 字节小端 → mod l → 32 字节小端
    static func reduce64(_ input: [UInt8]) -> [UInt8] {
        let r = BigLE.mod(input, orderLE)
        var out = r
        if out.count < 32 { out.append(contentsOf: [UInt8](repeating: 0, count: 32 - out.count)) }
        return Array(out.prefix(32))
    }
}

// MARK: - SPAKE2（复刻 BoringSSL spake25519）
final class Spake2 {
    enum Role { case alice, bob }
    private let role: Role
    private let myName: [UInt8]
    private let theirName: [UInt8]
    private var privateScalar: [UInt8] = []
    private var passwordScalar: [UInt8] = []
    private var passwordHash: [UInt8] = []
    private(set) var myMsg: [UInt8] = []
    private var processed = false

    /// adb 配对用的名字串（注意必须带结尾 '\0'，与 sizeof(kClientName) 一致）
    static let adbClientName = Array("adb pair client".utf8) + [0]
    static let adbServerName = Array("adb pair server".utf8) + [0]

    /// BoringSSL 预生成的两个掩码点（spake25519.cc 注释中的编码值）
    static let mEncoded: [UInt8] = [0x5a, 0xda, 0x7e, 0x4b, 0xf6, 0xdd, 0xd9, 0xad, 0xb6, 0x62, 0x6d, 0x32,
                                    0x13, 0x1c, 0x6b, 0x5c, 0x51, 0xa1, 0xe3, 0x47, 0xa3, 0x47, 0x8f, 0x53,
                                    0xcf, 0xcf, 0x44, 0x1b, 0x88, 0xee, 0xd1, 0x2e]
    static let nEncoded: [UInt8] = [0x10, 0xe3, 0xdf, 0x0a, 0xe3, 0x7d, 0x8e, 0x7a, 0x99, 0xb5, 0xfe, 0x74,
                                    0xb4, 0x46, 0x72, 0x10, 0x3d, 0xbd, 0xdc, 0xbd, 0x06, 0xaf, 0x68, 0x0d,
                                    0x71, 0x32, 0x9a, 0x11, 0x69, 0x3b, 0xc7, 0x78]

    init(role: Role, myName: [UInt8], theirName: [UInt8]) {
        self.role = role
        self.myName = myName
        self.theirName = theirName
    }

    convenience init(adbClient: Bool) {
        if adbClient {
            self.init(role: .alice, myName: Spake2.adbClientName, theirName: Spake2.adbServerName)
        } else {
            self.init(role: .bob, myName: Spake2.adbServerName, theirName: Spake2.adbClientName)
        }
    }

    /// SPAKE2_generate_msg。返回 32 字节消息。password 为「配对码 + TLS exporter」拼接。
    /// randomSource 仅测试用（固定随机数以便与参考实现对拍），生产传 nil。
    func generateMsg(password: [UInt8], randomSource: ((Int) -> [UInt8])? = nil) throws -> [UInt8] {
        // 1. 私钥：64 字节随机 → mod l → ×8
        let rnd = randomSource?(64) ?? {
            var r = [UInt8](repeating: 0, count: 64)
            let status = SecRandomCopyBytes(kSecRandomDefault, 64, &r)
            if status != errSecSuccess { fatalError("随机数生成失败") }
            return r
        }()
        var priv = EdScalar.reduce64(rnd)
        // left_shift_3：小端 ×8
        priv = BigLE.shl(priv, 3)
        privateScalar = priv

        // 2. P = priv * G
        let base = EdPoint.base()
        let p = base.scalarMul(priv)

        // 3. 掩码：password_scalar * M(alice)/N(bob)
        let hash = [UInt8](SHA512.hash(data: Data(password)))
        passwordHash = hash
        var passwordTmp = EdScalar.reduce64(hash)
        // 复刻「password scalar 修正」：加 l/2l/4l 使标量为 8 的倍数（纯 256 位加法，不再取模）
        let l = EdScalar.orderLE
        if BigLE.bit(passwordTmp, 0) == 1 { passwordTmp = BigLE.add(passwordTmp, l) }
        if BigLE.bit(passwordTmp, 1) == 1 { passwordTmp = BigLE.add(passwordTmp, BigLE.shl(l, 1)) }
        if BigLE.bit(passwordTmp, 2) == 1 { passwordTmp = BigLE.add(passwordTmp, BigLE.shl(l, 2)) }
        passwordScalar = passwordTmp

        let maskPoint = role == .alice ? try decodeOrThrow(Spake2.mEncoded) : try decodeOrThrow(Spake2.nEncoded)
        let mask = maskPoint.scalarMul(passwordTmp)

        // 4. P* = P + mask，编码输出
        let pstar = p.add(mask)
        myMsg = pstar.encode()
        return myMsg
    }

    /// SPAKE2_process_msg。返回 64 字节密钥。
    func processMsg(_ theirMsg: [UInt8]) throws -> [UInt8] {
        guard theirMsg.count == 32, !myMsg.isEmpty else { throw PairingCryptoError.badMessage }
        guard let qstar = EdPoint.decode(theirMsg) else { throw PairingCryptoError.pointDecode }
        let peersMaskPoint = role == .alice ? try decodeOrThrow(Spake2.nEncoded) : try decodeOrThrow(Spake2.mEncoded)
        let peersMask = peersMaskPoint.scalarMul(passwordScalar)
        let q = qstar.sub(peersMask)
        let dh = q.scalarMul(privateScalar)
        let dhBytes = dh.encode()

        var hasher = SHA512()
        func update(_ data: [UInt8]) {
            var lenLE = [UInt8](repeating: 0, count: 8)
            var l = data.count
            for i in 0..<8 { lenLE[i] = UInt8(l & 0xff); l >>= 8 }
            hasher.update(data: Data(lenLE))
            hasher.update(data: Data(data))
        }
        if role == .alice {
            update(myName); update(theirName); update(myMsg); update(theirMsg)
        } else {
            update(theirName); update(myName); update(theirMsg); update(myMsg)
        }
        update(dhBytes)
        update(passwordHash)
        processed = true
        return Array(hasher.finalize())
    }

    private func decodeOrThrow(_ bytes: [UInt8]) throws -> EdPoint {
        guard let p = EdPoint.decode(bytes) else { throw PairingCryptoError.pointDecode }
        return p
    }
}

// MARK: - 配对 AES-128-GCM（复刻 adb pairing_auth aes_128_gcm）
final class PairingCipher {
    private let key: SymmetricKey
    private var encSeq: UInt64 = 0
    private var decSeq: UInt64 = 0

    init(keyMaterial: [UInt8]) {
        // HKDF-SHA256(keyMaterial, salt=nil, info="adb pairing_auth aes-128-gcm key", 16 字节)
        let info = Array("adb pairing_auth aes-128-gcm key".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(keyMaterial)),
            salt: Data(),
            info: Data(info),
            outputByteCount: 16
        )
        key = derived
    }

    private static func nonce(_ seq: UInt64) -> Data {
        var n = Data(repeating: 0, count: 12)
        var s = seq.littleEndian
        withUnsafeBytes(of: &s) { n.replaceSubrange(0..<8, with: $0) }
        return n
    }

    func encrypt(_ plain: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: Self.nonce(encSeq)))
        encSeq &+= 1
        return sealed.ciphertext + sealed.tag
    }

    func decrypt(_ cipher: Data) throws -> Data {
        guard cipher.count > 16 else { throw PairingCryptoError.badMessage }
        let tag = cipher.suffix(16)
        let body = cipher.prefix(cipher.count - 16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Self.nonce(decSeq)),
                                        ciphertext: body, tag: tag)
        let out = try AES.GCM.open(box, using: key, authenticating: Data())
        decSeq &+= 1
        return out
    }
}

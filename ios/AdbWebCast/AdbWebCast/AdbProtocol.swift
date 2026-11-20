import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ADB 传输层常量（little-endian 32 位命令字）
extension Notification.Name {
    /// 首次 ADB 授权：App 已把签名发给电视，提示用户在电视上勾选「始终允许」并点 OK。
    static let adbAuthorizationRequired = Notification.Name("adbAuthorizationRequired")
    /// 连接/握手各阶段文字，用于把进度实时推到 UI，避免"始终正在连接"无反馈。
    static let adbConnectionStage = Notification.Name("adbConnectionStage")
}

enum AdbCmd {
    // 4 个 ASCII 字符按 little-endian 读成 uint32（与 dadb / adbd 一致）
    static let cnxn: UInt32 = 0x4e584e43 // "CNXN"
    static let auth: UInt32 = 0x48545541 // "AUTH"
    static let open: UInt32 = 0x4e45504f // "OPEN"
    static let okay: UInt32 = 0x59414b4f // "OKAY"
    static let wrte: UInt32 = 0x45545257 // "WRTE"
    static let clse: UInt32 = 0x45534c43 // "CLSE"
    static let fail: UInt32 = 0x4c494146 // "FAIL"

    // 官方 adb 使用的协议版本号（0x01000000 会被部分固件的版本校验拒绝）
    static let version: UInt32 = 0x01000001
    static let maxData: UInt32 = 1024 * 1024     // 我方单帧最大负载（官方 adb server 同值）
    static let connectPayload = "host::\u{0}"
}

enum AdbError: Error, LocalizedError {
    case connectionFailed(String)
    case handshakeFailed(String)
    case unauthorized
    case protocolError(String)
    case commandFailed(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "连接失败：\(s)"
        case .handshakeFailed(let s): return "ADB 握手失败：\(s)"
        case .unauthorized: return "未授权：请在电视上勾选「一律允许」后重试"
        case .protocolError(let s): return "协议错误：\(s)"
        case .commandFailed(let s): return s
        case .ioError(let s): return "网络错误：\(s)"
        }
    }
}

// MARK: - 24 字节 ADB 消息帧
struct AdbMessage {
    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var data: Data

    var header: Data {
        var d = Data()
        d.append(contentsOf: command.leBytes)
        d.append(contentsOf: arg0.leBytes)
        d.append(contentsOf: arg1.leBytes)
        d.append(contentsOf: UInt32(data.count).leBytes)
        var sum: UInt32 = 0
        for b in data { sum = sum &+ UInt32(b) }
        d.append(contentsOf: sum.leBytes)
        d.append(contentsOf: (command ^ 0xffffffff).leBytes)
        return d
    }
    var encoded: Data { header + data }
}

extension UInt32 {
    var leBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self), UInt8(truncatingIfNeeded: self >> 8),
         UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 24)]
    }
    static func fromLE(_ bytes: [UInt8]) -> UInt32 {
        var v: UInt32 = 0
        for (i, b) in bytes.prefix(4).enumerated() { v |= UInt32(b) << UInt32(8 * i) }
        return v
    }
}
extension Data {
    func u32le(_ offset: Int) -> UInt32 {
        guard count >= offset + 4 else { return 0 }
        return UInt32.fromLE(Array(self[offset..<(offset + 4)]))
    }
}

// MARK: - TCP socket 封装（阻塞式，带超时）
final class AdbSocket {
    private var fd: Int32 = -1
    var readTimeoutSeconds: Int = 20
    /// 共享连接是否被对端关闭（read()==0）。用于长连接复用前的健康检查。
    private(set) var remoteClosed = false
    var isValid: Bool { fd >= 0 && !remoteClosed }
    deinit { closeSocket() }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 6) throws {
        remoteClosed = false
        let sock = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard sock >= 0 else { throw AdbError.ioError("无法创建 socket") }
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ok = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard ok == 1 else { close(sock); throw AdbError.connectionFailed("IP 地址无效：\(host)") }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(sock, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let e = errno
            if e != EINPROGRESS && e != EALREADY {
                close(sock); throw AdbError.connectionFailed("\(host):\(port) 不可达")
            }
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let n = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, Int32(timeout * 1000)) }
            if n <= 0 { close(sock); throw AdbError.connectionFailed("连接 \(host):\(port) 超时") }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 { close(sock); throw AdbError.connectionFailed("\(host):\(port) 拒绝连接") }
        }
        _ = fcntl(sock, F_SETFL, flags)
        self.fd = sock
    }

    func setReadTimeout(_ seconds: Int) {
        readTimeoutSeconds = seconds
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func writeAll(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if n <= 0 { throw AdbError.ioError("写入失败") }
            sent += n
        }
    }

    func receiveExact(_ count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(count)
        let budgetMs = max(1000, readTimeoutSeconds * 1000)
        while out.count < count {
            // 用 poll 做硬超时：真机上 SO_RCVTIMEO 可能被半开连接/信号影响而失效，
            // poll 能保证任何一次读都有确定上限，绝不出现"永久正在连接"。
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, Int32(budgetMs)) }
            if ready == 0 { throw AdbError.ioError("读取超时(\(readTimeoutSeconds)s)") }
            if ready < 0 {
                if errno == EINTR { continue }
                throw AdbError.ioError("读取被中断")
            }
            let need = count - out.count
            var buf = [UInt8](repeating: 0, count: need)
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, need, 0) }
            if n == 0 { remoteClosed = true; closeSocket(); throw AdbError.ioError("电视已断开连接") }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw AdbError.ioError("读取失败(errno=\(errno))")
            }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func sendMessage(_ msg: AdbMessage) throws { try writeAll(msg.encoded) }

    /// 仅在 timeoutMs 内有数据可读时读一帧，否则返回 nil。用于关闭通道时快速消费对方确认，
    /// 不阻塞（实时屏幕循环每帧都会开关通道，不能用整秒超时）。
    func receiveMessageIfAvailable(timeoutMs: Int = 30) -> AdbMessage? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, Int32(timeoutMs)) }
        if ready <= 0 { return nil }
        return try? receiveMessage()
    }

    func receiveMessage() throws -> AdbMessage {
        let h = try receiveExact(24)
        let command = UInt32.fromLE(Array(h[0..<4]))
        let arg0 = UInt32.fromLE(Array(h[4..<8]))
        let arg1 = UInt32.fromLE(Array(h[8..<12]))
        let len = UInt32.fromLE(Array(h[12..<16]))
        let magic = UInt32.fromLE(Array(h[20..<24]))
        guard magic == (command ^ 0xffffffff) else {
            throw AdbError.protocolError("帧 magic 校验失败")
        }
        let data = len > 0 ? try receiveExact(Int(len)) : Data()
        return AdbMessage(command: command, arg0: arg0, arg1: arg1, data: data)
    }

    func closeSocket() { if fd >= 0 { close(fd); fd = -1 } }
}

// MARK: - 轻量探测：验证对端真的是 adbd（扫描去重 VPN 伪开放端口）
enum AdbProbe {
    /// TCP 连上后发一个 CNXN 帧，对端若回合法的 CNXN/AUTH 帧才认为是真 ADB 设备。
    static func verify(host: String, port: UInt16) -> Bool {
        let sock = AdbSocket()
        do {
            try sock.connect(host: host, port: port, timeout: 0.9)
            sock.setReadTimeout(2)
            let cnxn = AdbMessage(command: AdbCmd.cnxn, arg0: AdbCmd.version,
                                  arg1: 4096, data: AdbCmd.connectPayload.data(using: .utf8)!)
            try sock.sendMessage(cnxn)
            let reply = try sock.receiveMessage()   // magic 校验失败会抛错 → 判定非 ADB
            sock.closeSocket()
            return reply.command == AdbCmd.cnxn || reply.command == AdbCmd.auth
        } catch {
            sock.closeSocket()
            return false
        }
    }
}

// MARK: - ADB 客户端：握手 + shell + sync(push/pull/list/stat) + install
final class AdbClient {
    // ---- 全局共享长连接 ----
    // 关键修复：ADB 每建一条 TCP 连接都要走一次 RSA 授权握手，电视未勾选「始终允许」时
    // 每条新连接都会弹授权框。这里让全 App 所有功能复用同一条已认证连接，一次授权即可，
    // 不再每个功能重复握手；并用递归锁把命令串行化，避免多通道帧串台。
    private static let sharedSocket = AdbSocket()
    private static let connLock = NSRecursiveLock()
    private static var connectedKey = ""
    private static var idCounter: UInt32 = 1
    /// 帧缓存池：ADB 是多路复用协议，服务端可能先发来"上一条通道"的残留帧
    /// （如 WRTE/CLSE）。旧实现把它们当无关帧丢弃并计数报错，导致"过多无关帧"。
    /// 正确做法（adbkit/adb-shell 的 packet store）：按 arg1(localId) 暂存，
    /// 下次读该通道的帧时优先从池里匹配，绝不因乱序/残留误判协议错误。
    private static var packetStore: [UInt32: [AdbMessage]] = [:]
    /// 电视在握手 CNXN 回复里广播的 max_payload（arg1）。
    /// 官方 adb server 的铁律：发往设备的每一帧负载不得超过设备广播的 maxdata，
    /// 超限会被 adbd 的 check_header 直接判为坏包并杀掉整个连接（表现为推送挂死/断开）。
    /// 老固件（FireOS 5 / 老安卓盒子）通常只有 4096 或 64KB，绝不能按我方 1MB/64KB 硬发。
    private static var deviceMaxData: UInt32 = 4096
    /// 最近一次成功连接的设备（自动重连时复用，等价 adb server 的 transport 重启）
    private static var lastHost: String?
    private static var lastPort: UInt16 = 5555
    /// 复刻官方 adb server 的常驻行为：iOS 会杀掉后台空闲 TCP，回前台时主动废弃旧连接，
    /// 下一条命令自动重连（已授权电视 <1 秒、无授权弹窗），杜绝半开连接导致的卡死。
    private static let foregroundHook: Void = {
        #if canImport(UIKit)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { _ in AdbClient().invalidate() }
        #endif
        return ()
    }()

    private var socket: AdbSocket { Self.sharedSocket }

    private func allocLocalId() -> UInt32 {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let id = Self.idCounter
        Self.idCounter += 2
        return id
    }

    func connect(host: String, port: UInt16 = 5555) throws {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        _ = Self.foregroundHook   // 确保前台重连钩子已注册
        let key = "\(host):\(port)"
        Self.lastHost = host
        Self.lastPort = port
        // 同一设备且连接仍有效 → 直接复用，跳过握手（不再弹 RSA 授权框）
        if Self.connectedKey == key && Self.sharedSocket.isValid {
            AdbLog.log("连接复用 \(key)")
            return
        }
        AdbLog.log("新建连接 \(key)（原 key=\(Self.connectedKey.isEmpty ? "无" : Self.connectedKey)）")
        // 设备变更或旧连接已断 → 重建连接并握手
        Self.sharedSocket.closeSocket()
        Self.packetStore.removeAll()   // 新连接，丢弃旧通道的残留帧
        Self.deviceMaxData = 4096     // 新连接重新协商，先按最保守值发
        do {
            AdbLog.log("TCP 连接 \(host):\(port)")
            postStage("正在连接电视 \(host):\(port)…")
            try Self.sharedSocket.connect(host: host, port: port)
            // 握手超时按阶段内部分级控制（见 handshake），保证已授权电视秒级完成
            try handshake()
            Self.connectedKey = key
        } catch {
            Self.connectedKey = ""
            // 半开连接兜底：复用判定（isValid）检测不出"iOS 杀后台 TCP / 电视 adbd 重启"
            // 留下的死连接，首次握手会以网络错误失败。拆掉重连、重新握手一次——
            // 已授权电视 <1s 完成，等价 adb server 的传输自动重启。
            if case AdbError.ioError = error {
                AdbLog.log("连接失败，半开兜底重试：\(error.localizedDescription)", level: "W")
                Self.sharedSocket.closeSocket()
                Self.packetStore.removeAll()
                Self.deviceMaxData = 4096
                do {
                    postStage("检测到旧连接已失效，正在自动重连…")
                    try Self.sharedSocket.connect(host: host, port: port)
                    try handshake()
                    Self.connectedKey = key
                    return
                } catch {
                    Self.connectedKey = ""
                    throw error
                }
            }
            throw error
        }
    }

    private func handshake() throws {
        postStage("正在与电视握手…")
        let cnxn = AdbMessage(command: AdbCmd.cnxn, arg0: AdbCmd.version,
                              arg1: AdbCmd.maxData, data: AdbCmd.connectPayload.data(using: .utf8)!)
        try socket.sendMessage(cnxn)
        // 分级超时：已授权电视每一步都应在 1 秒内完成，快速失败不拖泥带水；
        // 只有"等待用户在电视上点 OK"这一步才给长超时。
        socket.setReadTimeout(10)
        var repliedSignature = false
        var repliedPublicKey = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let reply = try socket.receiveMessage()
            if reply.command == AdbCmd.cnxn {
                // 关键：CNXN 回复 arg0=版本 arg1=设备 maxdata。此后所有 WRTE 负载
                // 都必须 ≤ 该值（官方 adb server 的 min(MAX_PAYLOAD, 设备 maxdata) 行为）。
                if reply.arg1 > 0 { Self.deviceMaxData = min(reply.arg1, AdbCmd.maxData) }
                AdbLog.log("CNXN 完成：设备版本 0x\(String(reply.arg0, radix: 16)) maxdata=\(reply.arg1)B")
                postStage("授权成功（帧上限 \(Self.deviceMaxData)B），正在读取设备信息…")
                return
            }
            if reply.command == AdbCmd.auth && reply.arg0 == 1 {
                AdbLog.log("收到 AUTH token \(reply.data.count)B")
                let token = reply.data
                guard token.count == 20 else {
                    throw AdbError.handshakeFailed("授权令牌长度异常(\(token.count))")
                }
                if !repliedSignature, let key = AdbKeys.privateKey {
                    var error: Unmanaged<CFError>?
                    // ADB 把 20 字节 token 当作「已算好的 SHA1 摘要」，用 Digest 变体签名。
                    guard let sig = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) else {
                        let d: String
                        if let e = error { d = e.takeRetainedValue().localizedDescription }
                        else { d = "未知错误" }
                        throw AdbError.handshakeFailed("RSA 签名失败：\(d)")
                    }
                    try socket.sendMessage(AdbMessage(command: AdbCmd.auth, arg0: 2, arg1: 0, data: sig as Data))
                    AdbLog.log("已发送 AUTH 签名 \((sig as Data).count)B")
                    repliedSignature = true
                    // key 已存：电视立即回 CNXN；key 未存：立即回新 token（都应 <1s）
                    socket.setReadTimeout(8)
                    postStage("已发送签名，等待电视确认…")
                    NotificationCenter.default.post(name: .adbAuthorizationRequired, object: nil)
                    continue
                }
                if !repliedPublicKey, let pub = AdbKeys.publicBlob {
                    try socket.sendMessage(AdbMessage(command: AdbCmd.auth, arg0: 3, arg1: 0, data: pub))
                    AdbLog.log("已发送公钥 \(pub.count)B，等待电视授权")
                    repliedPublicKey = true
                    socket.setReadTimeout(35)   // 等用户在电视上勾选「一律允许」并点 OK
                    postStage("请在电视勾选「一律允许」并点 OK…")
                    continue
                }
                throw AdbError.handshakeFailed("电视未接受授权，请在电视勾选「一律允许」后重试")
            }
            throw AdbError.handshakeFailed("收到未知帧 0x\(String(reply.command, radix: 16))")
        }
        throw AdbError.handshakeFailed("握手超时（请在电视上确认授权提示）")
    }

    private func postStage(_ text: String) {
        NotificationCenter.default.post(name: .adbConnectionStage, object: text)
    }

    /// 断线重连（连接已持锁）。等价 adb server 的 transport 重启：用最近设备重新握手。
    private func reconnectLocked() throws {
        guard let h = Self.lastHost else { throw AdbError.connectionFailed("无可用连接") }
        Self.sharedSocket.closeSocket()
        Self.packetStore.removeAll()
        Self.connectedKey = ""
        Self.idCounter = 1
        try Self.sharedSocket.connect(host: h, port: Self.lastPort)
        try handshake()
        Self.connectedKey = "\(h):\(Self.lastPort)"
    }

    /// 复刻官方 adb server 的稳定性语义：任何传输层错误（断线/半开连接/帧异常/超时）
    /// 都自动重建连接并重试一次。已授权电视重连握手 <1 秒、无授权弹窗，用户完全无感知。
    /// 必须在已持有 connLock 的调用方里使用（递归锁）。
    private func withAutoReconnect<T>(_ op: () throws -> T) throws -> T {
        do { return try op() }
        catch let e as AdbError {
            var retriable = false
            if case .ioError = e { retriable = true }
            if case .protocolError = e { retriable = true }
            guard retriable, Self.lastHost != nil else { throw e }
            AdbLog.log("传输错误自动重连重试：\(e.localizedDescription)", level: "W")
            do { try reconnectLocked() } catch { AdbLog.log("重连失败：\(error.localizedDescription)", level: "E"); throw e }
            return try op()
        }
    }

    /// 服务端发来的帧：arg0 = remoteId，arg1 = localId。
    /// allowZeros 用于 OPEN 响应——部分设备的 OPEN OKAY 帧两参数可能带 0。
    private func argsMatch(_ m: AdbMessage, local: UInt32, remote: UInt32?, allowZeros: Bool = false) -> Bool {
        if allowZeros {
            return (m.arg1 == 0 || m.arg1 == local) && (remote == nil || m.arg0 == 0 || m.arg0 == remote!)
        }
        return m.arg1 == local && (remote == nil || m.arg0 == remote!)
    }

    /// 从缓存池或 socket 读取一帧：属于指定通道、且命令类型在 expected 内。
    /// 关键修复：不匹配的帧（残留/乱序）存入 packetStore 而非丢弃计数；
    /// 传输层 OKAY（对方确认我们发出的 WRTE）无信息量，直接消费不计入任何上限——
    /// 这正是"过多 OKAY 帧"误报的根因（push 大文件时几百个 OKAY 是正常流控）。
    private func readFrame(local: UInt32, remote: UInt32?, expected: Set<UInt32>,
                           allowZeros: Bool = false, timeout: TimeInterval? = nil) throws -> AdbMessage {
        // 1) 先扫缓存池，找本通道已暂存的匹配帧
        if var bucket = Self.packetStore[local] {
            for (i, m) in bucket.enumerated() {
                if argsMatch(m, local: local, remote: remote, allowZeros: allowZeros) && expected.contains(m.command) {
                    bucket.remove(at: i)
                    if bucket.isEmpty { Self.packetStore[local] = nil } else { Self.packetStore[local] = bucket }
                    return m
                }
            }
        }
        // 2) 从 socket 读，直到匹配（超时由 socket.receiveMessage 的 poll 硬超时控制）
        let deadline = Date().addingTimeInterval(timeout ?? 90)
        while Date() < deadline {
            let m = try socket.receiveMessage()
            if argsMatch(m, local: local, remote: remote, allowZeros: allowZeros) && expected.contains(m.command) {
                return m
            }
            // 传输层 OKAY 是对我们 WRTE 的确认，无数据，直接丢弃；其余帧按通道暂存
            if m.command != AdbCmd.okay {
                Self.packetStore[m.arg1, default: []].append(m)
            }
        }
        AdbLog.log("readFrame 超时：通道 \(local) expected=\(expected.map { String($0) }) 池内帧数=\(Self.packetStore.values.map(\.count).reduce(0, +))", level: "E")
        throw AdbError.protocolError("读取响应超时（通道 \(local)）")
    }

    private func open(_ destination: String) throws -> (UInt32, UInt32) {
        let local = allocLocalId()
        var svc = destination
        if !svc.hasSuffix("\u{0}") { svc += "\u{0}" }
        AdbLog.log("OPEN [\(local)] \(destination)")
        try socket.sendMessage(AdbMessage(command: AdbCmd.open, arg0: local, arg1: 0,
                                           data: svc.data(using: .utf8)!))
        let reply = try readFrame(local: local, remote: nil, expected: [AdbCmd.okay, AdbCmd.fail], allowZeros: true)
        if reply.command == AdbCmd.fail {
            AdbLog.log("OPEN [\(local)] 失败：\(String(data: reply.data, encoding: .utf8) ?? "")", level: "E")
            throw AdbError.commandFailed(String(data: reply.data, encoding: .utf8) ?? "服务打开失败")
        }
        AdbLog.log("OPEN [\(local)] OKAY remote=\(reply.arg0)")
        return (local, reply.arg0)
    }

    /// 关闭通道：发 CLSE，并读对方的 CLSE 确认完成双向关闭（短超时容错）。
    /// 旧实现发完 CLSE 就走，对方回的 CLSE 残留在 socket 污染下一条命令。
    private func closeChannel(local: UInt32, remote: UInt32) {
        try? socket.sendMessage(AdbMessage(command: AdbCmd.clse, arg0: local, arg1: remote, data: Data()))
        // 尽力消费对方的 CLSE 确认（30ms 上限，不阻塞实时屏幕刷新）；
        // 若读到的是别的通道帧，归入缓存池，绝不丢弃。
        if let m = socket.receiveMessageIfAvailable(timeoutMs: 30) {
            if !(m.arg1 == local && (m.command == AdbCmd.clse || m.command == AdbCmd.okay)) {
                Self.packetStore[m.arg1, default: []].append(m)
            }
        }
        Self.packetStore[local] = nil
    }

    /// 读取属于某通道的下一个 WRTE 数据帧：OKAY 由 readFrame 自动消费；收到 WRTE 回 OKAY；CLSE 回 CLSE 表示结束。
    private func receiveStreamData(local: UInt32, remote: UInt32) throws -> Data? {
        let msg = try readFrame(local: local, remote: remote, expected: [AdbCmd.wrte, AdbCmd.clse, AdbCmd.fail])
        if msg.command == AdbCmd.wrte {
            try socket.sendMessage(AdbMessage(command: AdbCmd.okay, arg0: local, arg1: remote, data: Data()))
            return msg.data
        } else if msg.command == AdbCmd.clse {
            // 关键：ADB 协议要求收到对方 CLSE 回 CLSE（不是 OKAY），否则通道状态错乱。
            try? socket.sendMessage(AdbMessage(command: AdbCmd.clse, arg0: local, arg1: remote, data: Data()))
            return nil
        } else {
            throw AdbError.commandFailed(String(data: msg.data, encoding: .utf8) ?? "命令失败")
        }
    }

    // MARK: shell

    /// 执行 shell 命令，返回 stdout/stderr 合并文本
    func shell(_ command: String, timeout: TimeInterval = 60) throws -> String {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let data = try shellData(command, timeout: timeout)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// 执行 shell 命令，返回原始字节（截图等二进制场景）。断线自动重连重试一次。
    func shellData(_ command: String, timeout: TimeInterval = 60) throws -> Data {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let cmdBrief = command.count > 120 ? String(command.prefix(120)) + "…" : command
        AdbLog.log("shell> \(cmdBrief)")
        let data = try withAutoReconnect {
            let (local, remote) = try open("shell:\(command)")
            defer { closeChannel(local: local, remote: remote) }
            socket.setReadTimeout(Int(timeout))
            var output = Data()
            while let chunk = try receiveStreamData(local: local, remote: remote) {
                output.append(chunk)
            }
            return output
        }
        AdbLog.log("shell< \(data.count)B")
        return data
    }

    func deviceModel() -> String {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        guard let out = try? shell("getprop ro.product.model", timeout: 8) else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一次连接批量读取所有设备属性。用一条 shell 命令把多个 getprop 串起来，
    /// 避免多次 open/close 通道；每条以换行分隔，定位符包裹便于切分。
    func readDeviceInfo() -> DeviceInfo {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        var d = DeviceInfo()
        // 关键：必须用 echo KEY=$(getprop ...) 保证 key 与值在【同一行】。
        // 旧写法 echo KEY=;getprop ... 会输出 "KEY=" 和值两行，解析时值全部落空
        // （表现为设备信息页除型号外全是"—"）。
        let cmd = [
            "echo M=$(getprop ro.product.model)",
            "echo B=$(getprop ro.product.brand)",
            "echo V=$(getprop ro.product.manufacturer)",
            "echo A=$(getprop ro.build.version.release)",
            "echo S=$(getprop ro.build.version.sdk)",
            "echo N=$(getprop ro.serialno)",
            "echo P=$(getprop ro.board.platform)",
            "echo R=$(wm size)",
            "echo C=$(dumpsys battery | grep -i level)",
        ].joined(separator: ";")
        guard let out = try? shell(cmd, timeout: 15) else {
            AdbLog.log("设备信息读取失败", level: "E")
            return d
        }
        var cur = ""
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("M=") { cur = "M"; d.model = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("B=") { cur = "B"; d.brand = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("V=") { cur = "V"; d.manufacturer = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("A=") { cur = "A"; d.androidVersion = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("S=") { cur = "S"; d.sdk = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("N=") { cur = "N"; d.serialno = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("P=") { cur = "P"; d.cpu = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("R=") { cur = "R"; d.resolution = String(s.dropFirst(2)).trimmed; continue }
            if s.hasPrefix("C=") { cur = "C"; d.battery = String(s.dropFirst(2)).trimmed; continue }
            // 续行（值本身含换行，如 wm size 可能多行）
            if !s.isEmpty {
                switch cur {
                case "M": if d.model.isEmpty { d.model = s }
                case "R": if d.resolution.isEmpty || d.resolution.hasPrefix("Physical") { d.resolution += " " + s }
                default: break
                }
            }
        }
        return d
    }

    // MARK: sync 子协议

    private static var dentSeen = 0

    private func openSync() throws -> (UInt32, UInt32) {
        let ch = try open("sync:\u{0}")
        Self.syncBuffer.removeAll()   // 新通道/重试后都从空流开始
        Self.dentSeen = 0
        return ch
    }

    // MARK: sync 字节流读取（黏包/跨帧安全，对齐 adbkit 的 parser 行为）
    // 关键点 1：adbd 会把多个 DENT/DATA 包黏进一个 WRTE 帧、也会把一个包拆到多帧，
    // 必须按字节流读，与帧边界完全解耦（旧实现按"帧=完整包"解析会解析错位挂死）。
    // 关键点 2：响应包格式不统一——DENT 无 length 字段（固定 20B 头），
    // 其余包为 id(4)+len(4)+body，见 receiveSyncPacket 的按 id 分支解析。
    private static var syncBuffer = Data()

    /// 读取 n 字节 sync 流数据；对端 CLSE（EOF）返回 nil。
    private func readSyncBytes(_ n: Int, local: UInt32, remote: UInt32) throws -> Data? {
        while Self.syncBuffer.count < n {
            let msg = try readFrame(local: local, remote: remote, expected: [AdbCmd.wrte, AdbCmd.clse, AdbCmd.fail])
            if msg.command == AdbCmd.wrte {
                try socket.sendMessage(AdbMessage(command: AdbCmd.okay, arg0: local, arg1: remote, data: Data()))
                Self.syncBuffer.append(msg.data)
            } else if msg.command == AdbCmd.clse {
                try? socket.sendMessage(AdbMessage(command: AdbCmd.clse, arg0: local, arg1: remote, data: Data()))
                return nil   // EOF
            } else {
                throw AdbError.commandFailed(String(data: msg.data, encoding: .utf8) ?? "sync 命令失败")
            }
        }
        let out = Data(Self.syncBuffer.prefix(n))
        Self.syncBuffer.removeSubrange(0..<min(n, Self.syncBuffer.count))
        return out
    }

    /// 单个 WRTE 负载上限 = min(64KB, 设备 maxdata)。与 adbkit 的 DATA_MAX_LENGTH=65536
    /// 一致，并叠加官方 adb server 的「不超过设备广播 maxdata」规则。
    private var frameLimit: Int {
        max(1024, min(64 * 1024, Int(Self.deviceMaxData)))
    }

    /// 发送一个 WRTE 数据帧，并等待设备的 OKAY 流控确认后再返回。
    /// 关键修复：官方 adb server（remote_socket.c）转发数据时是「发一帧 → 等设备 OKAY →
    /// 再发下一帧」。旧实现背靠背连发不等确认，属于协议违规——部分 adbd（老索尼固件等）
    /// 会丢弃流水线里的后续帧：表现为 sync 的 LIST 发出后电视无任何响应、
    /// push/RECV 偶发挂死。对齐官方流控后此问题根治。
    private func sendWrte(_ payload: Data, local: UInt32, remote: UInt32) throws {
        try socket.sendMessage(AdbMessage(command: AdbCmd.wrte, arg0: local, arg1: remote, data: payload))
        // 等待本通道的 OKAY 确认（arg0=remoteId, arg1=localId）。期间到达的其它帧
        // 由 readFrame 归入缓存池，绝不丢失。OKAY 是毫秒级响应，超时视为通道异常。
        _ = try readFrame(local: local, remote: remote, expected: [AdbCmd.okay], timeout: 15)
    }

    /// 发送一个 sync 包（4 字节 ID + 4 字节小端长度 + body）。
    /// 关键修复：sync 包头单独一帧、body 按设备 maxdata 分帧——这正是官方 adb server
    /// 转发数据时的分帧方式。旧实现把 8 字节包头和 64KB body 拼进同一个 WRTE（65548 字节），
    /// 一旦超过设备 max_payload（老固件 4096/64KB），adbd 的 check_header 会判为坏包
    /// 并直接断开整个连接——表现为"安装一直卡住/安装中无响应"。
    private func sendSyncFrame(_ id: String, body: Data, local: UInt32, remote: UInt32) throws {
        var header = Data(id.utf8)
        header.append(contentsOf: UInt32(body.count).leBytes)
        try sendWrte(header, local: local, remote: remote)
        var off = 0
        while off < body.count {
            let n = min(frameLimit, body.count - off)
            try sendWrte(body.subdata(in: off..<(off + n)), local: local, remote: remote)
            off += n
        }
    }

    /// 读取一个 sync 响应包，返回 (4 字节 ID, body)；EOF 返回 nil。黏包/跨帧安全。
    /// 关键修复（2026-11-20 真机实证：Sony BRAVIA 4K UR3 / Fire TV AFTKA，均 Android 9）：
    /// adbd 的 sync 响应里【只有 DENT 没有 length 字段】——
    ///   DENT: id(4) + mode(4) + size(4) + mtime(4) + namelen(4) + name（固定 20B 头）
    ///   DONE/OKAY: id(4) + 0 填充（实测 adbd 至少跟 4 字节 0，DONE 共 20B）
    ///   FAIL/DATA: id(4) + len(4) + payload
    /// 旧实现统一按「8 字节头」解析，把 DENT 的 mode 字段误读为 length（如 0x41f9=16889B）
    /// → 死等不存在的数据 → 超时。这就是「VIDAA adbd 对 LIST 零响应怪癖」的真因——
    /// 怪癖根本不存在，正确解析后两台电视 sync LIST 均 0.1s 返回。
    private func receiveSyncPacket(local: UInt32, remote: UInt32) throws -> (String, Data)? {
        guard let idData = try readSyncBytes(4, local: local, remote: remote), idData.count == 4 else {
            return nil
        }
        let id = String(data: idData, encoding: .ascii) ?? ""
        var body = Data()
        switch id {
        case "DENT":
            guard let stat = try readSyncBytes(16, local: local, remote: remote), stat.count == 16 else {
                return nil
            }
            body = stat
            let nlen = Int(stat.u32le(12))
            if nlen > 0 {
                guard let name = try readSyncBytes(nlen, local: local, remote: remote), name.count == nlen else {
                    return nil
                }
                body.append(name)
            }
            Self.dentSeen += 1
            if Self.dentSeen <= 3 || Self.dentSeen % 50 == 0 { AdbLog.log("sync<DENT #\(Self.dentSeen) name_len=\(nlen)") }
        case "DONE", "OKAY", "QUIT", "FAIL", "DATA":
            guard let lenData = try readSyncBytes(4, local: local, remote: remote), lenData.count == 4 else {
                return nil
            }
            let len = Int(lenData.u32le(0))
            guard len >= 0 else { throw AdbError.protocolError("sync 包长度异常 \(len)") }
            body = len > 0 ? (try readSyncBytes(len, local: local, remote: remote)) ?? Data() : Data()
            AdbLog.log("sync<\(id) len=\(len)")
        default:
            throw AdbError.protocolError("sync 未知响应包 \(id)")
        }
        return (id, body)
    }

    /// sync 推送本地文件到设备。断线自动重连重试一次（从头重推，幂等安全）。
    func push(localURL: URL, remotePath: String, progress: (Int) -> Void) throws {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        try withAutoReconnect {
            socket.setReadTimeout(90)
            let (local, remote) = try openSync()
            defer { closeChannel(local: local, remote: remote) }
            let mode: UInt32 = 0o100644
            AdbLog.log("SEND \(remotePath)（分块 \(frameLimit)B）")
            try sendSyncFrame("SEND", body: "\(remotePath),\(mode)".data(using: .utf8)!, local: local, remote: remote)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard let handle = try? FileHandle(forReadingFrom: localURL) else {
                throw AdbError.commandFailed("无法读取文件")
            }
            defer { try? handle.close() }
            var sent = 0
            while true {
                let chunk = (try? handle.read(upToCount: frameLimit)) ?? Data()
                if chunk.isEmpty { break }
                try sendSyncFrame("DATA", body: chunk, local: local, remote: remote)
                sent += chunk.count
                progress(fileSize > 0 ? min(99, Int(Double(sent) / Double(fileSize) * 100)) : 50)
            }
            // 关键修复（真机实证）：DONE 包的官方格式是「时间戳放在 4 字节 length 字段位、
            // 无 body」——即单帧 payload = "DONE" + 4 字节时间戳。旧实现发 body
            // （头 len=4 + 4 字节 body），adbd 读完头就把时间戳取走并结束发送流程，
            // body 被当作下一个 sync 包的垃圾 id → 不回 ACK → 卡死超时。
            var doneFrame = Data("DONE".utf8)
            doneFrame.append(contentsOf: UInt32(Date().timeIntervalSince1970).leBytes)
            try sendWrte(doneFrame, local: local, remote: remote)

            guard let (id, body) = try receiveSyncPacket(local: local, remote: remote) else {
                throw AdbError.protocolError("sync 通道提前关闭")
            }
            if id == "FAIL" {
                throw AdbError.commandFailed("推送失败：\(String(data: body, encoding: .utf8) ?? "未知错误")")
            }
            guard id == "OKAY" else { throw AdbError.protocolError("sync 返回未知包 \(id)") }
            // QUIT：单帧、不等 ACK——adbd 收到 QUIT 直接关闭 sync 服务，可能不回确认，
            // 等待只会撞上 15s 超时。失败也无关紧要（连接随 closeChannel 关闭）。
            var quitFrame = Data("QUIT".utf8)
            quitFrame.append(contentsOf: UInt32(0).leBytes)
            try? socket.sendMessage(AdbMessage(command: AdbCmd.wrte, arg0: local, arg1: remote, data: quitFrame))
            progress(100)
        }
    }

    /// sync 从设备拉取文件到本地，进度 0-100。断线自动重连重试一次。
    func pull(remotePath: String, to localURL: URL, progress: (Int) -> Void) throws {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        try withAutoReconnect {
            socket.setReadTimeout(90)
            let (local, remote) = try openSync()
            defer { closeChannel(local: local, remote: remote) }
            AdbLog.log("RECV \(remotePath)")
            try sendSyncFrame("RECV", body: remotePath.data(using: .utf8)!, local: local, remote: remote)
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: localURL) else {
                throw AdbError.commandFailed("无法写入本地文件")
            }
            defer { try? handle.close() }
            while let (id, body) = try receiveSyncPacket(local: local, remote: remote) {
                if id == "DONE" { break }
                if id == "FAIL" {
                    throw AdbError.commandFailed("下载失败：\(String(data: body, encoding: .utf8) ?? "未知错误")")
                }
                guard id == "DATA" else { throw AdbError.protocolError("sync 返回未知包 \(id)") }
                try? handle.write(contentsOf: body)
            }
            progress(100)
        }
    }

    /// 列目录（sync LIST → DENT/DONE）。断线自动重连重试一次。
    /// 2026-11-20 真机实证：此前"部分固件（VIDAA 等）对 LIST 永不响应"的怪癖并不存在，
    /// 真因是 receiveSyncPacket 把 DENT 的 mode 字段误读为 length（见该函数注释）。
    /// 修复后 Sony BRAVIA / Fire TV 均 0.1s 返回。brokenHosts 兜底机制保留作安全网，
    /// 仅在个别未验证固件上真出现怪癖时才会触发。
    private static var syncListBrokenHosts: Set<String> = []

    func listDir(_ path: String) throws -> [RemoteFile] {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let hostKey = Self.connectedKey
        if !Self.syncListBrokenHosts.contains(hostKey) {
            do {
                return try withAutoReconnect { try listDirViaSync(path) }
            } catch let e as AdbError {
                // 仅对「sync 服务零响应超时」切换 shell 兜底；FAIL（权限等）照常抛出
                guard case .protocolError = e, Self.lastHost != nil else { throw e }
                Self.syncListBrokenHosts.insert(hostKey)
                AdbLog.log("sync LIST 无响应（设备 adbd 怪癖），已切换 shell 列目录并对该主机记忆", level: "W")
            }
        }
        return try shellListDir(path)
    }

    /// sync LIST 实现（8 秒短超时，失败立刻切兜底而不是干等 90 秒）
    private func listDirViaSync(_ path: String) throws -> [RemoteFile] {
        socket.setReadTimeout(8)
        let (local, remote) = try openSync()
        defer { closeChannel(local: local, remote: remote) }
        AdbLog.log("LIST \(path)")
        try sendSyncFrame("LIST", body: path.data(using: .utf8)!, local: local, remote: remote)
        var result: [RemoteFile] = []
        AdbLog.log("LIST 开始等待响应…")
        while let (id, body) = try receiveSyncPacket(local: local, remote: remote) {
            if id == "DONE" { break }
            if id == "FAIL" {
                throw AdbError.commandFailed("读取目录失败：\(String(data: body, encoding: .utf8) ?? "未知错误")")
            }
            guard id == "DENT", body.count >= 16 else { continue }
            let mode = body.u32le(0)
            let size = Int64(body.u32le(4))
            let mtime = body.u32le(8)
            let nameLen = Int(body.u32le(12))
            let name = nameLen > 0 && body.count >= 16 + nameLen
                ? String(data: body.subdata(in: 16..<(16 + nameLen)), encoding: .utf8) ?? ""
                : ""
            if name.isEmpty || name == "." || name == ".." { continue }
            result.append(RemoteFile(name: name, path: path.hasSuffix("/") ? path + name : path + "/" + name,
                                      isDir: (mode & 0o170000) == 0o040000, size: size,
                                      mtime: Date(timeIntervalSince1970: Double(mtime)), mode: mode))
        }
        AdbLog.log("LIST 完成：\(result.count) 项")
        return result.sorted { l, r in
            if l.isDir != r.isDir { return l.isDir }
            return l.name < r.name
        }
    }

    /// shell 列目录兜底：shell 通道在这批电视上 100% 可靠。
    /// 首选 stat -c（toybox/busybox 都支持，一次拿全类型/大小/mtime，且 name 在最后一列可含 | 与空格）；
    /// 输出为空再退回 ls -ap（目录名带 "/" 后缀，仅名与目录标志）。
    private func shellListDir(_ path: String) throws -> [RemoteFile] {
        socket.setReadTimeout(30)
        let q = path.replacingOccurrences(of: "'", with: "'\\''")
        AdbLog.log("shell LIST 兜底 \(path)")
        let out = try shell("find '\(q)' -maxdepth 1 -mindepth 1 -exec stat -L -c \"%F|%s|%Y|%n\" {} + 2>/dev/null", timeout: 30)
        var result: [RemoteFile] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            // name 在最后一列，用 maxSplit=3 切分，文件名里含 "|" 也安全
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            let kind = String(parts[0])
            let size = Int64(parts[1]) ?? 0
            let mtime = TimeInterval(parts[2]) ?? 0
            let full = String(parts[3])
            let name = full.split(separator: "/").last.map(String.init) ?? full
            if name.isEmpty { continue }
            result.append(RemoteFile(name: name, path: full,
                                      isDir: kind.contains("directory"), size: size,
                                      mtime: Date(timeIntervalSince1970: mtime), mode: 0))
        }
        if result.isEmpty {
            // 极老固件 find/stat 不全 → ls -ap：目录带 "/" 后缀
            let lsOut = (try? shell("ls -ap '\(q)' 2>/dev/null", timeout: 20)) ?? ""
            for line in lsOut.split(separator: "\n", omittingEmptySubsequences: true) {
                var name = String(line)
                guard name != "./", name != "../" else { continue }
                let isDir = name.hasSuffix("/")
                if isDir { name.removeLast() }
                if name.isEmpty { continue }
                result.append(RemoteFile(name: name,
                                          path: path.hasSuffix("/") ? path + name : path + "/" + name,
                                          isDir: isDir, size: 0,
                                          mtime: Date(), mode: 0))
            }
        }
        AdbLog.log("shell LIST 完成：\(result.count) 项")
        return result.sorted { l, r in
            if l.isDir != r.isDir { return l.isDir }
            return l.name < r.name
        }
    }

    /// 截图：完全对齐 adbkit（Web 版经官方 adb server 的实际调用）——
    /// 命令 `echo && screencap -p 2>/dev/null`：
    /// 1) 先 echo 输出一个换行，用于探测本流的新行约定；
    /// 2) stderr 丢弃，防止老设备把告警并进 shell 输出污染 PNG；
    /// 3) 仅当探测到 CRLF（设备 shell 走 PTY 把 \n 换成 \r\n）才做 \r\n→\n 还原，
    ///    否则原样透传。旧实现"只要 PNG 里出现 0d0a 就全量替换"会把合法 PNG 数据
    ///    改坏（压缩流里几乎必然有 0d0a 字节对）→ 一直报"截图数据无效"。
    func screenshot() throws -> Data {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let raw = try shellData("echo && screencap -p 2>/dev/null", timeout: 90)
        guard let nl = raw.firstIndex(of: 0x0a) else { return raw }
        let crlfMangled = nl > raw.startIndex && raw[raw.index(before: nl)] == 0x0d
        var png = raw.subdata(in: raw.index(after: nl)..<raw.endIndex)   // 丢弃 echo 的探测行
        if crlfMangled {
            var fixed = Data(); fixed.reserveCapacity(png.count)
            let bytes = [UInt8](png)
            var i = 0
            while i < bytes.count {
                if i + 1 < bytes.count, bytes[i] == 0x0d, bytes[i + 1] == 0x0a {
                    fixed.append(0x0a); i += 2
                } else { fixed.append(bytes[i]); i += 1 }
            }
            png = fixed
        }
        // 电视侧 screencap 失败时（典型：正在播放 DRM/受保护画面，或 surface 被安全图层占用），
        // shell 只回显 echo 的 1 个换行。返回 <100 字节视为抓帧失败，明确报错——
        // 实时屏幕循环必须感知失败做退避熔断，否则会 155ms 一次无限重试打爆电视（v3.0.1 用户日志实证）。
        guard png.count >= 100 else {
            AdbLog.log("screencap 仅返回 \(png.count)B，电视侧抓帧失败", level: "W")
            throw AdbError.commandFailed("电视未返回画面数据（\((png.count))B）。常见原因：电视正在播放受保护内容（DRM/安全图层），回到桌面后再试")
        }
        return png
    }

    /// 常见 pm install 失败码 → 用户可读的中文说明
    private static let installErrorHints: [String: String] = [
        "INSTALL_FAILED_VERSION_DOWNGRADE": "电视上已安装更高版本，系统拒绝降级。请先在电视上卸载旧版再装，或安装更高版本的 APK。",
        "INSTALL_FAILED_UPDATE_INCOMPATIBLE": "已安装的同名应用签名不一致，需先卸载旧版。",
        "INSTALL_FAILED_INSUFFICIENT_STORAGE": "电视存储空间不足，请先清理空间。",
        "INSTALL_PARSE_FAILED_NO_CERTIFICATES": "APK 未签名或证书异常。",
        "INSTALL_PARSE_FAILED_INCONSISTENT_CERTIFICATES": "与已安装应用的签名不一致，需先卸载旧版。",
        "INSTALL_FAILED_INVALID_APK": "APK 文件损坏或不完整，请重新获取安装包。",
        "INSTALL_FAILED_NO_MATCHING_ABIS": "APK 不含本机 CPU 架构的 so 库，无法安装。",
        "INSTALL_FAILED_INVALID_URI": "安装路径无效。",
        "INSTALL_FAILED_ALREADY_EXISTS": "已存在相同版本的应用。",
    ]

    /// 推送 + pm install 完整流程。-d 允许降级（-r 覆盖重装）。
    func installAPK(localURL: URL, progress: (Int) -> Void) throws -> String {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let base = localURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        let remotePath = "/data/local/tmp/adbios_\(Int(Date().timeIntervalSince1970))_\(base).apk"
        AdbLog.log("install push → \(remotePath)")
        try push(localURL: localURL, remotePath: remotePath, progress: progress)
        progress(99)
        AdbLog.log("pm install 开始…")
        let output = try shell("pm install -r -d \(remotePath)", timeout: 120)
        AdbLog.log("pm install 输出：\(output.trimmed.prefix(200))")
        _ = try? shell("rm -f \(remotePath)", timeout: 10)
        progress(100)
        // 把 "Failure [CODE]" 翻译成用户能看懂的提示
        var out = output.trimmed
        if let m = out.range(of: #"Failure \[([A-Z_]+)\]"#, options: .regularExpression) {
            let code = out[m].replacingOccurrences(of: "Failure [", with: "").replacingOccurrences(of: "]", with: "")
            if let hint = Self.installErrorHints[code] { out += "\n💡 \(hint)" }
        }
        return out
    }

    /// 保留共享长连接供其他功能复用（不再每次操作关闭连接、导致下次重新授权）。
    func disconnect() { /* no-op：授权态随共享连接保留 */ }
    /// 仅在切换设备/确认连接失效时主动废弃共享连接。
    func invalidate() {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        Self.sharedSocket.closeSocket()
        Self.connectedKey = ""
    }
    deinit { /* 共享连接由 App 生命周期管理，不随单个页面/实例释放 */ }
}

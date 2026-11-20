import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
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

    static let version: UInt32 = 0x01000000      // ADB 协议版本 1.0.0
    static let maxData: UInt32 = 1024 * 1024     // 单帧最大负载（dadb 用 1MB）
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

    private var socket: AdbSocket { Self.sharedSocket }

    private func allocLocalId() -> UInt32 {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let id = Self.idCounter
        Self.idCounter += 2
        return id
    }

    func connect(host: String, port: UInt16 = 5555) throws {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let key = "\(host):\(port)"
        // 同一设备且连接仍有效 → 直接复用，跳过握手（不再弹 RSA 授权框）
        if Self.connectedKey == key && Self.sharedSocket.isValid { return }
        // 设备变更或旧连接已断 → 重建连接并握手
        Self.sharedSocket.closeSocket()
        Self.packetStore.removeAll()   // 新连接，丢弃旧通道的残留帧
        do {
            postStage("正在连接电视 \(host):\(port)…")
            try Self.sharedSocket.connect(host: host, port: port)
            // 握手阶段要给用户在电视上点「OK」留出时间；配合 poll 硬超时保证有上限
            Self.sharedSocket.setReadTimeout(40)
            try handshake()
            Self.connectedKey = key
        } catch {
            Self.connectedKey = ""
            throw error
        }
    }

    private func handshake() throws {
        postStage("正在与电视握手…")
        let cnxn = AdbMessage(command: AdbCmd.cnxn, arg0: AdbCmd.version,
                              arg1: AdbCmd.maxData, data: AdbCmd.connectPayload.data(using: .utf8)!)
        try socket.sendMessage(cnxn)
        var repliedSignature = false
        var repliedPublicKey = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let reply = try socket.receiveMessage()
            if reply.command == AdbCmd.cnxn {
                postStage("授权成功，正在读取设备信息…")
                return
            }
            if reply.command == AdbCmd.auth && reply.arg0 == 1 {
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
                    repliedSignature = true
                    postStage("已发送签名，等待电视确认…")
                    NotificationCenter.default.post(name: .adbAuthorizationRequired, object: nil)
                    continue
                }
                if !repliedPublicKey, let pub = AdbKeys.publicBlob {
                    try socket.sendMessage(AdbMessage(command: AdbCmd.auth, arg0: 3, arg1: 0, data: pub))
                    repliedPublicKey = true
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
        throw AdbError.protocolError("读取响应超时（通道 \(local)）")
    }

    private func open(_ destination: String) throws -> (UInt32, UInt32) {
        let local = allocLocalId()
        var svc = destination
        if !svc.hasSuffix("\u{0}") { svc += "\u{0}" }
        try socket.sendMessage(AdbMessage(command: AdbCmd.open, arg0: local, arg1: 0,
                                           data: svc.data(using: .utf8)!))
        let reply = try readFrame(local: local, remote: nil, expected: [AdbCmd.okay, AdbCmd.fail], allowZeros: true)
        if reply.command == AdbCmd.fail {
            throw AdbError.commandFailed(String(data: reply.data, encoding: .utf8) ?? "服务打开失败")
        }
        return (local, reply.arg0)
    }

    /// 关闭通道：发 CLSE，并读对方的 CLSE 确认完成双向关闭（短超时容错）。
    /// 旧实现发完 CLSE 就走，对方回的 CLSE 残留在 socket 污染下一条命令。
    private func closeChannel(local: UInt32, remote: UInt32) {
        try? socket.sendMessage(AdbMessage(command: AdbCmd.clse, arg0: local, arg1: remote, data: Data()))
        // 尽力消费对方的 CLSE 确认（30ms 上限，不阻塞实时屏幕刷新）；
        // 若读到的是别的通道帧，归入缓存池，绝不丢弃。
        if let m = socket.receiveMessageIfAvailable(30) {
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

    /// 执行 shell 命令，返回原始字节（截图等二进制场景）
    func shellData(_ command: String, timeout: TimeInterval = 60) throws -> Data {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let (local, remote) = try open("shell:\(command)")
        defer { closeChannel(local: local, remote: remote) }
        socket.setReadTimeout(Int(timeout))
        var output = Data()
        while let chunk = try receiveStreamData(local: local, remote: remote) {
            output.append(chunk)
        }
        return output
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
        guard let out = try? shell(cmd, timeout: 15) else { return d }
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

    private func openSync() throws -> (UInt32, UInt32) { try open("sync:\u{0}") }

    /// 发送一个 sync 包（4 字节 ID + 4 字节小端长度 + body），封装在 A_WRTE 中
    private func sendSyncPacket(_ id: String, body: Data, local: UInt32, remote: UInt32) throws {
        var payload = Data(id.utf8)              // 恰好 4 字节 ASCII
        payload.append(contentsOf: UInt32(body.count).leBytes)
        payload.append(body)
        try socket.sendMessage(AdbMessage(command: AdbCmd.wrte, arg0: local, arg1: remote, data: payload))
    }

    /// 读取一个 sync 响应包，返回 (4 字节 ID, body)。跳过传输层 OKAY。
    private func receiveSyncPacket(local: UInt32, remote: UInt32) throws -> (String, Data) {
        guard let frame = try receiveStreamData(local: local, remote: remote), frame.count >= 8 else {
            throw AdbError.protocolError("sync 响应帧异常")
        }
        let id = String(data: frame.prefix(4), encoding: .ascii) ?? ""
        let len = Int(frame.u32le(4))
        let body = len > 0 ? frame.subdata(in: 8..<min(8 + len, frame.count)) : Data()
        return (id, body)
    }

    /// sync 推送本地文件到设备
    func push(localURL: URL, remotePath: String, progress: (Int) -> Void) throws {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        socket.setReadTimeout(90)
        let (local, remote) = try openSync()
        defer { closeChannel(local: local, remote: remote) }
        let mode: UInt32 = 0o100644
        try sendSyncPacket("SEND", body: "\(remotePath),\(mode)".data(using: .utf8)!, local: local, remote: remote)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw AdbError.commandFailed("无法读取文件")
        }
        defer { try? handle.close() }
        var sent = 0
        while true {
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            try sendSyncPacket("DATA", body: chunk, local: local, remote: remote)
            sent += chunk.count
            progress(fileSize > 0 ? min(99, Int(Double(sent) / Double(fileSize) * 100)) : 50)
        }
        try sendSyncPacket("DONE", body: Data(UInt32(Date().timeIntervalSince1970).leBytes), local: local, remote: remote)

        let (id, body) = try receiveSyncPacket(local: local, remote: remote)
        if id == "FAIL" {
            throw AdbError.commandFailed("推送失败：\(String(data: body, encoding: .utf8) ?? "未知错误")")
        }
        guard id == "OKAY" else { throw AdbError.protocolError("sync 返回未知包 \(id)") }
        try sendSyncPacket("QUIT", body: Data(), local: local, remote: remote)
        progress(100)
    }

    /// sync 从设备拉取文件到本地，进度 0-100
    func pull(remotePath: String, to localURL: URL, progress: (Int) -> Void) throws {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        socket.setReadTimeout(90)
        let (local, remote) = try openSync()
        defer { closeChannel(local: local, remote: remote) }
        try sendSyncPacket("RECV", body: remotePath.data(using: .utf8)!, local: local, remote: remote)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw AdbError.commandFailed("无法写入本地文件")
        }
        defer { try? handle.close() }
        while true {
            let (id, body) = try receiveSyncPacket(local: local, remote: remote)
            if id == "DONE" { break }
            if id == "FAIL" {
                throw AdbError.commandFailed("下载失败：\(String(data: body, encoding: .utf8) ?? "未知错误")")
            }
            guard id == "DATA" else { throw AdbError.protocolError("sync 返回未知包 \(id)") }
            try? handle.write(contentsOf: body)
        }
        progress(100)
    }

    /// 列目录（sync LIST → DENT/DONE）
    func listDir(_ path: String) throws -> [RemoteFile] {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        socket.setReadTimeout(90)
        let (local, remote) = try openSync()
        defer { closeChannel(local: local, remote: remote) }
        try sendSyncPacket("LIST", body: path.data(using: .utf8)!, local: local, remote: remote)
        var result: [RemoteFile] = []
        while true {
            let (id, body) = try receiveSyncPacket(local: local, remote: remote)
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
        return result.sorted { l, r in
            if l.isDir != r.isDir { return l.isDir }
            return l.name < r.name
        }
    }

    /// 截图：screencap -p → PNG。部分老设备把 \n 输出成 \r\n，需还原。
    func screenshot() throws -> Data {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        var png = try shellData("screencap -p", timeout: 90)
        let crlf = Data([0x0d, 0x0a]), lf = Data([0x0a])
        if png.range(of: crlf) != nil {
            var fixed = Data(); var i = 0
            while i < png.count {
                if i + 1 < png.count, png[i] == 0x0d, png[i + 1] == 0x0a {
                    fixed.append(lf); i += 2
                } else { fixed.append(png[i]); i += 1 }
            }
            png = fixed
        }
        return png
    }

    /// 推送 + pm install 完整流程
    func installAPK(localURL: URL, progress: (Int) -> Void) throws -> String {
        Self.connLock.lock(); defer { Self.connLock.unlock() }
        let base = localURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        let remotePath = "/data/local/tmp/adbios_\(Int(Date().timeIntervalSince1970))_\(base).apk"
        try push(localURL: localURL, remotePath: remotePath, progress: progress)
        progress(99)
        let output = try shell("pm install -r \(remotePath)", timeout: 120)
        _ = try? shell("rm -f \(remotePath)", timeout: 10)
        progress(100)
        return output
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

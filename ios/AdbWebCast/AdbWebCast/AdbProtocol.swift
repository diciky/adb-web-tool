import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - ADB 传输层常量（little-endian 32 位命令字）
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

    // 服务字符串必须以 NUL 结尾
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
// 字段顺序（全部 little-endian）：command, arg0, arg1, data_length, data_checksum, magic
// checksum = payload 每个字节（无符号）求和；magic = command ^ 0xffffffff
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

    var encoded: Data {
        var d = header
        d.append(data)
        return d
    }
}

extension UInt32 {
    var leBytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self),
         UInt8(truncatingIfNeeded: self >> 8),
         UInt8(truncatingIfNeeded: self >> 16),
         UInt8(truncatingIfNeeded: self >> 24)]
    }
    static func fromLE(_ bytes: [UInt8]) -> UInt32 {
        var v: UInt32 = 0
        for (i, b) in bytes.prefix(4).enumerated() { v |= UInt32(b) << UInt32(8 * i) }
        return v
    }
}

// MARK: - TCP socket 封装（阻塞式，带超时）
final class AdbSocket {
    private var fd: Int32 = -1
    var readTimeoutSeconds: Int = 20

    deinit { closeSocket() }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 6) throws {
        let sock = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard sock >= 0 else { throw AdbError.ioError("无法创建 socket") }

        // 非阻塞 connect + select 实现连接超时
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ok = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard ok == 1 else {
            close(sock); throw AdbError.connectionFailed("IP 地址无效：\(host)")
        }
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
            // 用 poll 等待可写，规避 Swift 对 fd_set/FD_ZERO 宏导入不完整的问题
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let n = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, Int32(timeout * 1000)) }
            if n <= 0 { close(sock); throw AdbError.connectionFailed("连接 \(host):\(port) 超时") }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &len)
            if soError != 0 { close(sock); throw AdbError.connectionFailed("\(host):\(port) 拒绝连接") }
        }
        // 恢复阻塞，后续收发用 SO_RCVTIMEO
        _ = fcntl(sock, F_SETFL, flags)
        self.fd = sock
    }

    func setReadTimeout(_ seconds: Int) {
        readTimeoutSeconds = seconds
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // 注意：方法名不能叫 send，否则会遮蔽 C 的 send()，这里改名避免冲突
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
        while out.count < count {
            let need = count - out.count
            var buf = [UInt8](repeating: 0, count: need)
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                recv(fd, raw.baseAddress, need, 0)
            }
            if n <= 0 { throw AdbError.ioError("读取超时或连接中断") }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func sendMessage(_ msg: AdbMessage) throws {
        try writeAll(msg.encoded)
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

    func closeSocket() {
        if fd >= 0 { close(fd); fd = -1 }
    }
}

// MARK: - ADB 客户端：握手 + shell + sync push + install
final class AdbClient {
    private let socket = AdbSocket()
    private var nextLocalId: UInt32 = 1

    private func allocLocalId() -> UInt32 {
        let id = nextLocalId
        nextLocalId += 2
        return id
    }

    func connect(host: String, port: UInt16 = 5555) throws {
        try socket.connect(host: host, port: port)
        socket.setReadTimeout(20)
        try handshake()
    }

    // CNXN 握手 + AUTH 鉴权
    private func handshake() throws {
        let cnxn = AdbMessage(command: AdbCmd.cnxn, arg0: AdbCmd.version,
                              arg1: AdbCmd.maxData, data: AdbCmd.connectPayload.data(using: .utf8)!)
        try socket.sendMessage(cnxn)

        var repliedSignature = false
        var repliedPublicKey = false
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let reply = try socket.receiveMessage()
            if reply.command == AdbCmd.cnxn {
                // 连接建立成功
                return
            }
            if reply.command == AdbCmd.auth && reply.arg0 == 1 {
                // 设备发来 20 字节 token，先回签名（type=2），再回公钥（type=3）
                let token = reply.data
                if !repliedSignature, let key = AdbKeys.privateKey {
                    var error: Unmanaged<CFError>?
                    // ADB 把 20 字节 token 当作「已算好的 SHA1 摘要」，
                    // 因此用 Digest 变体（内部只加 DigestInfo + PKCS1v15 填充），不能再哈希一次。
                    if let sig = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) {
                        try socket.sendMessage(AdbMessage(command: AdbCmd.auth, arg0: 2, arg1: 0, data: sig as Data))
                        repliedSignature = true
                        continue
                    }
                }
                if !repliedPublicKey, let pub = AdbKeys.publicBlob {
                    try socket.sendMessage(AdbMessage(command: AdbCmd.auth, arg0: 3, arg1: 0, data: pub))
                    repliedPublicKey = true
                    continue
                }
                throw AdbError.handshakeFailed("无法完成鉴权")
            }
            throw AdbError.handshakeFailed("收到未知帧 0x\(String(reply.command, radix: 16))")
        }
        throw AdbError.handshakeFailed("握手超时（请在电视上确认授权提示）")
    }

    // 打开一个服务通道，返回 (localId, remoteId)。服务串统一补 NUL 结尾（dadb writeOpen 行为）。
    private func open(_ destination: String) throws -> (UInt32, UInt32) {
        let local = allocLocalId()
        var svc = destination
        if !svc.hasSuffix("\u{0}") { svc += "\u{0}" }
        try socket.sendMessage(AdbMessage(command: AdbCmd.open, arg0: local, arg1: 0,
                                           data: svc.data(using: .utf8)!))
        let reply = try socket.receiveMessage()
        // 响应帧中 arg1 = 我们这端的 localId，arg0 = 设备分配的 remoteId（与 dadb getLocalId 一致）
        guard reply.command == AdbCmd.okay, reply.arg1 == local else {
            if reply.command == AdbCmd.fail {
                throw AdbError.commandFailed(String(data: reply.data, encoding: .utf8) ?? "服务打开失败")
            }
            throw AdbError.protocolError("OPEN 未获 OKAY")
        }
        return (local, reply.arg0)
    }

    private func closeChannel(local: UInt32, remote: UInt32) {
        try? socket.sendMessage(AdbMessage(command: AdbCmd.clse, arg0: local, arg1: remote, data: Data()))
    }

    /// 执行 shell 命令，返回 stdout/stderr 合并文本
    func shell(_ command: String, timeout: TimeInterval = 60) throws -> String {
        let (local, remote) = try open("shell:\(command)")
        defer { closeChannel(local: local, remote: remote) }
        socket.setReadTimeout(Int(timeout))
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msg = try socket.receiveMessage()
            if msg.command == AdbCmd.wrte {
                output.append(msg.data)
                // 每个 WRITE 都要回 OKAY 做流控
                try socket.sendMessage(AdbMessage(command: AdbCmd.okay, arg0: local, arg1: remote, data: Data()))
            } else if msg.command == AdbCmd.clse {
                break
            } else if msg.command == AdbCmd.fail {
                throw AdbError.commandFailed(String(data: msg.data, encoding: .utf8) ?? "命令失败")
            }
        }
        return String(data: output, encoding: .utf8) ?? String(decoding: output, as: UTF8.self)
    }

    /// 读取设备型号，用于列表展示（失败不影响主流程）
    func deviceModel() -> String {
        guard let out = try? shell("getprop ro.product.model", timeout: 8) else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// sync 协议推送本地文件到设备。
    /// 关键点：sync 子命令（SEND/DATA/DONE）作为 A_WRTE 连续发出，设备不逐条回传输层 OKAY，
    /// 只在全部结束后回一个 sync 层的 "OKAY"/"FAIL" 包（adamkit / dadb 都是这个语义）。
    func push(localURL: URL, remotePath: String, progress: (Int) -> Void) throws {
        let (local, remote) = try open("sync:\u{0}")
        defer { closeChannel(local: local, remote: remote) }

        // SEND <path>,<mode>  mode=0o100644=33188
        let mode: UInt32 = 0o100644
        let arg = "\(remotePath),\(mode)"
        try sendSyncPacket("SEND", body: arg.data(using: .utf8)!, local: local, remote: remote)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard let handle = try? FileHandle(forReadingFrom: localURL) else {
            throw AdbError.commandFailed("无法读取 APK 文件")
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var sent = 0
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            try sendSyncPacket("DATA", body: chunk, local: local, remote: remote)
            sent += chunk.count
            let pct = fileSize > 0 ? min(99, Int(Double(sent) / Double(fileSize) * 100)) : 50
            progress(pct)
        }

        // DONE + 4 字节时间戳（秒）
        let ts = UInt32(Date().timeIntervalSince1970)
        try sendSyncPacket("DONE", body: Data(ts.leBytes), local: local, remote: remote)

        // 设备回的 sync 包封装在一个 A_WRTE 帧里，先解帧再读 4 字节 ID + 4 字节长度
        let frame = try socket.receiveMessage()
        guard frame.command == AdbCmd.wrte, frame.data.count >= 8 else {
            throw AdbError.protocolError("sync 响应帧异常")
        }
        let tag = String(data: frame.data.prefix(4), encoding: .ascii) ?? ""
        let extraLen = UInt32.fromLE(Array(frame.data[4..<8]))
        if tag == "FAIL" {
            let msg = extraLen > 0 ? frame.data.subdata(in: 8..<min(8 + Int(extraLen), frame.data.count)) : Data()
            throw AdbError.commandFailed("推送失败：\(String(data: msg, encoding: .utf8) ?? "未知错误")")
        }
        guard tag == "OKAY" else { throw AdbError.protocolError("sync 返回未知包 \(tag)") }

        // 回一个传输层 OKAY，再发 QUIT 结束 sync 会话
        try socket.sendMessage(AdbMessage(command: AdbCmd.okay, arg0: local, arg1: remote, data: Data()))
        try sendSyncPacket("QUIT", body: Data(), local: local, remote: remote)
        progress(100)
    }

    /// 组装并发送一个 sync 包（4 字节 ASCII 命令 + 4 字节小端长度 + body），封装在 A_WRTE 中。
    private func sendSyncPacket(_ cmd: String, body: Data, local: UInt32, remote: UInt32) throws {
        var payload = Data(cmd.utf8)
        payload.append(contentsOf: UInt32(body.count).leBytes)
        payload.append(body)
        try socket.sendMessage(AdbMessage(command: AdbCmd.wrte, arg0: local, arg1: remote, data: payload))
    }

    /// 推送 + pm install 的完整安装流程；进度 0-100
    func installAPK(localURL: URL, progress: (Int) -> Void) throws -> String {
        let base = localURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        let name = "adbios_\(Int(Date().timeIntervalSince1970))_\(base).apk"
        let remotePath = "/data/local/tmp/\(name)"

        try push(localURL: localURL, remotePath: remotePath, progress: progress)
        progress(99)
        let output = try shell("pm install -r \(remotePath)", timeout: 120)
        _ = try? shell("rm -f \(remotePath)", timeout: 10)
        progress(100)
        return output
    }

    func disconnect() { socket.closeSocket() }
    deinit { socket.closeSocket() }
}

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
    deinit { closeSocket() }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 6) throws {
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
        while out.count < count {
            let need = count - out.count
            var buf = [UInt8](repeating: 0, count: need)
            let n = buf.withUnsafeMutableBytes { raw -> Int in recv(fd, raw.baseAddress, need, 0) }
            if n <= 0 { throw AdbError.ioError("读取超时或连接中断") }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func sendMessage(_ msg: AdbMessage) throws { try writeAll(msg.encoded) }

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
    private let socket = AdbSocket()
    private var nextLocalId: UInt32 = 1

    private func allocLocalId() -> UInt32 { let id = nextLocalId; nextLocalId += 2; return id }

    func connect(host: String, port: UInt16 = 5555) throws {
        try socket.connect(host: host, port: port)
        socket.setReadTimeout(20)
        try handshake()
    }

    private func handshake() throws {
        let cnxn = AdbMessage(command: AdbCmd.cnxn, arg0: AdbCmd.version,
                              arg1: AdbCmd.maxData, data: AdbCmd.connectPayload.data(using: .utf8)!)
        try socket.sendMessage(cnxn)
        var repliedSignature = false
        var repliedPublicKey = false
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let reply = try socket.receiveMessage()
            if reply.command == AdbCmd.cnxn { return }
            if reply.command == AdbCmd.auth && reply.arg0 == 1 {
                let token = reply.data
                if !repliedSignature, let key = AdbKeys.privateKey {
                    var error: Unmanaged<CFError>?
                    // ADB 把 20 字节 token 当作「已算好的 SHA1 摘要」，用 Digest 变体。
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
                throw AdbError.handshakeFailed("无法完成鉴权，请在电视上确认授权提示")
            }
            throw AdbError.handshakeFailed("收到未知帧 0x\(String(reply.command, radix: 16))")
        }
        throw AdbError.handshakeFailed("握手超时（请在电视上确认授权提示）")
    }

    private func open(_ destination: String) throws -> (UInt32, UInt32) {
        let local = allocLocalId()
        var svc = destination
        if !svc.hasSuffix("\u{0}") { svc += "\u{0}" }
        try socket.sendMessage(AdbMessage(command: AdbCmd.open, arg0: local, arg1: 0,
                                           data: svc.data(using: .utf8)!))
        let reply = try socket.receiveMessage()
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

    /// 读取属于某通道的下一个 WRTE 数据帧：跳过对方回的传输层 OKAY；收到 WRTE 回 OKAY；CLSE 表示结束。
    private func receiveStreamData(local: UInt32, remote: UInt32) throws -> Data? {
        while true {
            let msg = try socket.receiveMessage()
            if msg.command == AdbCmd.okay {
                // 对方确认我们发出的 WRTE，无需再回，跳过
                continue
            } else if msg.command == AdbCmd.wrte {
                try socket.sendMessage(AdbMessage(command: AdbCmd.okay, arg0: local, arg1: remote, data: Data()))
                return msg.data
            } else if msg.command == AdbCmd.clse {
                return nil
            } else if msg.command == AdbCmd.fail {
                throw AdbError.commandFailed(String(data: msg.data, encoding: .utf8) ?? "命令失败")
            }
        }
    }

    // MARK: shell

    /// 执行 shell 命令，返回 stdout/stderr 合并文本
    func shell(_ command: String, timeout: TimeInterval = 60) throws -> String {
        let data = try shellData(command, timeout: timeout)
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// 执行 shell 命令，返回原始字节（截图等二进制场景）
    func shellData(_ command: String, timeout: TimeInterval = 60) throws -> Data {
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
        guard let out = try? shell("getprop ro.product.model", timeout: 8) else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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
        var png = try shellData("screencap -p", timeout: 30)
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

    func disconnect() { socket.closeSocket() }
    deinit { socket.closeSocket() }
}

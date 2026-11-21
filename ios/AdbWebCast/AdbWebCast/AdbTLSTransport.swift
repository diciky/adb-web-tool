import Foundation
import Network
import Security

// MARK: - TLS 传输层（Android 11+ 无线调试 adbd 强制 TLS 1.3 + 客户端证书）
// 与 AdbSocket 完全同构的阻塞式接口，底层用 NWConnection。
// 安全策略：
//  - 服务端证书不校验（配对码通过 SPAKE2 绑定 TLS 会话；RSA AUTH 层另有一层设备确认）
//  - 客户端证书 = 内置 ADB RSA 密钥对应的自签名证书（配对时已把该公钥授权给设备）

final class AdbTLSTransport: AdbTransport {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "adb.tls.transport")
    private let lock = NSLock()
    private var buffer = Data()
    private var readError: Error?
    private var eof = false
    private var receivePending = false
    private var wakeup = DispatchSemaphore(value: 0)
    private var _readTimeout: Int = 20

    var readTimeoutSeconds: Int {
        get { _readTimeout }
        set { _readTimeout = newValue }
    }
    private(set) var remoteClosed = false
    var isValid: Bool { connection != nil && !eof && !remoteClosed && readError == nil }

    deinit { connection?.cancel() }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 6) throws {
        buffer.removeAll()
        readError = nil
        eof = false
        remoteClosed = false
        receivePending = false

        let tlsOptions = NWProtocolTLS.Options()
        let sec = tlsOptions.securityProtocolOptions
        // adbd 无线调试只接受 TLS 1.3
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        // 服务端证书：全部信任（见文件头安全策略说明）
        sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, queue)
        // 客户端证书：adbd 要求客户端证书公钥已在授权列表（配对时授权）
        if let secIdentity = AdbIdentity.shared.secIdentity(),
           let identity = sec_identity_create(secIdentity) {
            sec_protocol_options_set_local_identity(sec, identity)
        } else {
            AdbLog.log("TLS 连接缺少客户端证书身份", level: "W")
        }

        let params = NWParameters(tls: tlsOptions)
        params.allowLocalEndpointReuse = true
        #if canImport(UIKit)
        params.connectTimeout = max(3, Int(timeout))
        #else
        // macOS 无 connectTimeout；本地 e2e 测试用，读超时兜底
        _ = timeout
        #endif

        guard let ep = NWEndpoint.Port(rawValue: port) else {
            throw AdbError.connectionFailed("端口无效：\(port)")
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: ep, using: params)
        let sem = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let error):
                self?.lock.lock()
                self?.readError = error
                self?.lock.unlock()
                sem.signal()
            case .cancelled:
                sem.signal()
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
        let result = sem.wait(timeout: .now() + timeout + 4)
        if result == .timedOut {
            conn.cancel()
            connection = nil
            throw AdbError.connectionFailed("TLS 连接 \(host):\(port) 超时")
        }
        if let error = readError {
            connection = nil
            throw AdbError.connectionFailed("TLS 连接 \(host):\(port) 失败：\(error.localizedDescription)")
        }
        if connection == nil {
            throw AdbError.connectionFailed("TLS 连接已取消")
        }
        AdbLog.log("TLS 握手完成 \(host):\(port)")
    }

    func setReadTimeout(_ seconds: Int) { _readTimeout = seconds }

    func writeAll(_ data: Data) throws {
        guard let conn = connection else { throw AdbError.ioError("TLS 连接未建立") }
        let sem = DispatchSemaphore(value: 0)
        var sendError: Error?
        conn.send(content: data, completion: .contentProcessed { error in
            sendError = error
            sem.signal()
        })
        if sem.wait(timeout: .now() + .seconds(max(_readTimeout, 10))) == .timedOut {
            throw AdbError.ioError("TLS 写入超时")
        }
        if let e = sendError { throw AdbError.ioError("TLS 写入失败：\(e.localizedDescription)") }
    }

    func receiveExact(_ count: Int) throws -> Data {
        try fill(minimum: count, timeoutMs: max(1000, _readTimeout * 1000))
        lock.lock()
        let out = buffer.prefix(count)
        buffer.removeFirst(min(count, buffer.count))
        lock.unlock()
        return Data(out)
    }

    /// 在 timeoutMs 内尝试凑出一整帧，凑不出返回 nil（缓冲区内容保留）
    func receiveMessageIfAvailable(timeoutMs: Int) -> AdbMessage? {
        // 先探测能否快速凑出 24 字节头
        do {
            try fill(minimum: 24, timeoutMs: timeoutMs)
        } catch {
            return nil
        }
        guard let header = try? receiveExact(24) else { return nil }
        let len = Int(UInt32.fromLE(Array(header[12..<16])))
        guard let payload = len > 0 ? try? receiveExact(len) : Data() else { return nil }
        let command = UInt32.fromLE(Array(header[0..<4]))
        let magic = UInt32.fromLE(Array(header[20..<24]))
        guard magic == (command ^ 0xffffffff) else { return nil }
        return AdbMessage(command: command,
                          arg0: UInt32.fromLE(Array(header[4..<8])),
                          arg1: UInt32.fromLE(Array(header[8..<12])),
                          data: payload)
    }

    func closeSocket() {
        lock.lock()
        eof = true
        let conn = connection
        connection = nil
        lock.unlock()
        conn?.cancel()
        wakeup.signal()
    }

    /// TLS exporter（配对协议用）：复刻 SSL_export_keying_material(ssl, 64, "adb-label\0", 9→10B, nil, 0, false)
    func exportKeyingMaterial(length: Int, label: [UInt8]) -> [UInt8]? {
        guard let conn = connection else { return nil }
        guard let meta = conn.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        let labelData = Data(label)
        let out = labelData.withUnsafeBytes { labelPtr -> dispatch_data_t? in
            guard let base = labelPtr.bindMemory(to: CChar.self).baseAddress else { return nil }
            return sec_protocol_metadata_create_secret(meta.securityProtocolMetadata,
                                                       labelData.count,
                                                       base,
                                                       length)
        }
        guard let out else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        let dd = out as DispatchData
        let n = min(length, dd.count)
        dd.withUnsafeBytes { (raw: UnsafePointer<UInt8>) in
            bytes.replaceSubrange(0..<n, with: UnsafeBufferPointer(start: raw, count: n))
        }
        return bytes
    }

    // MARK: 内部：阻塞填充缓冲区
    private func fill(minimum: Int, timeoutMs: Int) throws {
        while true {
            lock.lock()
            if buffer.count >= minimum { lock.unlock(); return }
            if let e = readError { lock.unlock(); throw e }
            if eof || remoteClosed {
                lock.unlock()
                remoteClosed = true
                throw AdbError.ioError("电视已断开连接")
            }
            if !receivePending, let conn = connection {
                receivePending = true
                conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                    guard let self else { return }
                    self.lock.lock()
                    self.receivePending = false
                    if let data, !data.isEmpty { self.buffer.append(data) }
                    if let error {
                        self.readError = AdbError.ioError("TLS 读取失败：\(error.localizedDescription)")
                    } else if isComplete, (data?.isEmpty ?? true) {
                        self.eof = true
                        self.remoteClosed = true
                    }
                    self.lock.unlock()
                    self.wakeup.signal()
                }
            }
            lock.unlock()
            let wait = wakeup.wait(timeout: .now() + .milliseconds(timeoutMs))
            if wait == .timedOut {
                throw AdbError.ioError("读取超时(\(_readTimeout)s)")
            }
        }
    }
}

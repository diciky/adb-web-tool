import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 常见 ADB TCP 端口（国产电视/盒子大量不用默认 5555）：
/// - 5555：adb tcpip 默认
/// - 5554/5556-5560：多实例与厂商定制固件（当贝 OS 5556、模拟器 5554 等）
/// - 5114：部分网络机顶盒实测端口
/// - 5037：个别设备把 adb server 端口直接暴露在局域网
/// - 62001：夜神等安卓模拟器（同网段调试也顺手支持）
enum AdbScanPorts {
    static let extended: [UInt16] = [5555, 5554, 5556, 5557, 5558, 5559, 5560, 5114, 5037, 62001]
}

/// 扫描到的一个开放 ADB 端口的主机
struct AdbHost: Identifiable, Hashable {
    let id = UUID()
    let ip: String
    let port: UInt16
    var serial: String { "\(ip):\(port)" }
    func hash(into h: inout Hasher) { h.combine(ip); h.combine(port) }
    static func == (l: AdbHost, r: AdbHost) -> Bool { l.ip == r.ip && l.port == r.port }
}

/// 本机网络接口信息
struct LocalInterface {
    let name: String
    let ip: String
    let netmask: String
}

/// 局域网扫描器：读取本机 IP → 推导 /24 → TCP 探测 → ADB 握手验证。
/// 完全只读网络探测，不修改任何网络设备配置。
final class LanScanner {

    /// 枚举本机所有活跃的 IPv4 接口，过滤回环/链路本地/VPN/蜂窝虚拟网卡。
    static func localInterfaces(includeVirtual: Bool = false) -> [LocalInterface] {
        var result: [LocalInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }

        let skipPrefixes = ["utun", "pdp_ip", "awdl", "llw", "bridge", "ipsec", "gif", "stf", "lo"]
        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            if ifa.ifa_addr != nil, ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if !includeVirtual && skipPrefixes.contains(where: { name.hasPrefix($0) }) {
                    ptr = ifa.ifa_next; continue
                }
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let ok = getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                                     &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
                if ok == 0 {
                    let ip = String(cString: hostBuf)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        var mask = "255.255.255.0"
                        if let nm = ifa.ifa_netmask {
                            var maskBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            if getnameinfo(nm, socklen_t(nm.pointee.sa_len),
                                           &maskBuf, socklen_t(maskBuf.count), nil, 0, NI_NUMERICHOST) == 0 {
                                mask = String(cString: maskBuf)
                            }
                        }
                        result.append(LocalInterface(name: name, ip: ip, netmask: mask))
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }

    /// 由 IP 推导 /24 网段前缀
    static func subnetBase(of ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// 纯 TCP 探测端口是否可连接（快速预判，后续还要 ADB 握手验证）。
    /// 多端口 × 254 主机时单次超时不能太长，300ms 在普通 WiFi 上足够可靠。
    static func tcpOpen(ip: String, port: UInt16, timeoutMs: Int = 300) -> Bool {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ok = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard ok == 1 else { return false }
        let r = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r == 0 { return true }
        let e = errno
        if e != EINPROGRESS && e != EALREADY { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let n = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, Int32(timeoutMs)) }
        if n <= 0 { return false }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0
    }

    /// 校验 IP 串合法性
    static func validIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy { $0 >= 0 && $0 <= 255 }
    }

    /// 扫描给定 /24 网段；TCP 预判通过后再做 ADB 握手验证；并发执行，主线程回调。
    /// 网段扫描对每个 IP 逐个尝试 ports 里的全部端口（国产设备常见 5556/5114 等非标端口）。
    static func scan(bases: [String], singleIPs: [String] = [], ports: [UInt16] = AdbScanPorts.extended,
                     onFound: @escaping (AdbHost) -> Void,
                     onDone: @escaping (Int) -> Void) {
        var targets: [(String, UInt16)] = []
        for base in Set(bases) {
            for last in 1...254 {
                for port in ports { targets.append(("\(base).\(last)", port)) }
            }
        }
        for ip in Set(singleIPs) {
            for p in ports { targets.append((ip, p)) }
        }

        var found = Set<AdbHost>()
        let lock = NSLock()
        let queue = DispatchQueue(label: "adb.lan.scan", attributes: .concurrent)
        let group = DispatchGroup()

        for (ip, port) in targets {
            group.enter()
            queue.async {
                // 先快速 TCP 预判，避免对每个 IP 都做 ADB 握手
                if tcpOpen(ip: ip, port: port), AdbProbe.verify(host: ip, port: port) {
                    let host = AdbHost(ip: ip, port: port)
                    var isNew = false
                    lock.lock()
                    if !found.contains(host) { found.insert(host); isNew = true }
                    lock.unlock()
                    if isNew { DispatchQueue.main.async { onFound(host) } }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { onDone(found.count) }
    }

    /// 自动扫描：取本机（非虚拟）网卡的 /24
    static func scanLocalNetwork(ports: [UInt16] = [5555],
                                 onFound: @escaping (AdbHost) -> Void,
                                 onDone: @escaping ([LocalInterface], Int) -> Void) {
        let ifaces = localInterfaces()
        let bases = ifaces.compactMap { subnetBase(of: $0.ip) }
        scan(bases: bases, ports: ports, onFound: onFound) { found in onDone(ifaces, found) }
    }
}

/// Bonjour/mDNS 发现：Android 11+ 无线调试会用 `_adb-tls-connect._tcp` 广播随机端口，
/// 老系统部分电视用 `_adb._tcp`。这类动态端口无法靠固定列表扫出来，必须靠 mDNS。
/// iOS 14+ 需要在 Info.plist 的 NSBonjourServices 里声明这两个服务类型，并授权本地网络。
final class AdbBonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private let onFound: (String, UInt16) -> Void

    init(onFound: @escaping (String, UInt16) -> Void) {
        self.onFound = onFound
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
        browser.searchForServices(ofType: "_adb._tcp.", inDomain: "local.")
    }

    func stop() {
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
        guard sender.port > 0, let ip = sender.addresses?.compactMap(Self.ipv4(from:)).first else { return }
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

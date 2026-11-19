import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 扫描到的一个开放 ADB 端口的主机
struct AdbHost: Identifiable, Hashable {
    let id = UUID()
    let ip: String
    let port: UInt16
    var serial: String { "\(ip):\(port)" }
}

/// 本机网络接口信息
struct LocalInterface {
    let name: String
    let ip: String
    let netmask: String
}

/// 局域网扫描器：读取本机 IP（WiFi / 个人热点 / 以太网）→ 推导 /24 → 并发 TCP 探测。
/// 完全只读网络探测，不修改任何网络设备配置。
final class LanScanner {

    /// 枚举本机所有活跃的 IPv4 接口（排除回环、链路本地 169.254）。
    static func localInterfaces() -> [LocalInterface] {
        var result: [LocalInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let p = ptr {
            let ifa = p.pointee
            if ifa.ifa_addr != nil, ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
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

    /// 由 IP + 掩码推导 /24 网段前缀（取前三段）。对 /16、/28 等也退化为所在 /24，覆盖常见家庭/热点网段。
    static func subnetBase(of ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// 网络序探测单个 host:port 是否可连接（TCP connect），带超时。
    static func probe(ip: String, port: UInt16, timeoutMs: Int = 420) -> Bool {
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

        var set = fd_set(); FD_ZERO(&set); FD_SET(fd, &set)
        var tv = timeval(tv_sec: 0, tv_usec: timeoutMs * 1000)
        let n = withUnsafeMutablePointer(to: &set) { setPtr -> Int32 in
            withUnsafeMutablePointer(to: &tv) { tvPtr in
                select(fd + 1, nil, setPtr, nil, tvPtr)
            }
        }
        if n <= 0 { return false }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0
    }

    /// 扫描给定的若干个 /24 网段的指定端口。并发执行，回调在主线程。
    /// - parameters:
    ///   - bases: 网段前缀数组，如 ["10.10.10", "172.20.10"]
    ///   - ports: 要探测的端口，默认 5555
    ///   - onFound: 每发现一个主机回调一次（主线程）
    ///   - onDone: 扫描完成回调（主线程）
    static func scan(bases: [String], ports: [UInt16] = [5555],
                     onFound: @escaping (AdbHost) -> Void,
                     onDone: @escaping (Int) -> Void) {
        var targets: [(String, UInt16)] = []
        for base in Set(bases) {
            for last in 1...254 {
                let ip = "\(base).\(last)"
                for p in ports { targets.append((ip, p)) }
            }
        }

        let total = targets.count
        var found = 0
        let lock = NSLock()
        let queue = DispatchQueue(label: "adb.lan.scan", attributes: .concurrent)
        let group = DispatchGroup()

        for (ip, port) in targets {
            group.enter()
            queue.async {
                if probe(ip: ip, port: port) {
                    lock.lock(); found += 1; lock.unlock()
                    DispatchQueue.main.async { onFound(AdbHost(ip: ip, port: port)) }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { onDone(found) }
        _ = total
    }

    /// 便捷入口：自动取本机所有网段的 /24 进行扫描
    static func scanLocalNetwork(ports: [UInt16] = [5555],
                                 onFound: @escaping (AdbHost) -> Void,
                                 onDone: @escaping ([LocalInterface], Int) -> Void) {
        let ifaces = localInterfaces()
        let bases = ifaces.compactMap { subnetBase(of: $0.ip) }
        scan(bases: bases, ports: ports, onFound: onFound) { found in
            onDone(ifaces, found)
        }
    }
}

import Darwin
import Foundation
import VPNGuardCore

/// The probes of the protection test: try to get out straight through one network card, outside the VPN.
/// Plain sockets bound to the card (the same idea as `ping -b en0`). Runs off the main thread.
enum ProtectionProbe {
    static func run(interface: String, label: String) -> LeakProbe {
        LeakProbe(interface: interface, label: label,
                  internetGotOut: tcpConnects(to: LeakTest.testAddress, port: 443, interface: interface, timeout: 3),
                  dnsGotOut: dnsAnswers(server: LeakTest.testAddress, interface: interface, timeout: 2.5),
                  ipv6GotOut: hasIPv6(interface: interface)
                      ? (tcpConnects(to: LeakTest.testAddress6, port: 443, interface: interface, timeout: 3) ?? false)
                      : nil)
    }

    /// `VPNGuard --probe en0` prints what gets out straight through that card and exits (for debugging
    /// and for docs/TROUBLESHOOTING.md). The same probes as Settings → General → Test Now….
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--probe"), i + 1 < args.count else { return }
        let p = run(interface: args[i + 1], label: args[i + 1])
        func word(_ b: Bool?) -> String { b.map { $0 ? "GOT OUT" : "blocked" } ?? "not tested" }
        print("direct internet (\(LeakTest.testAddress):443 through \(p.interface)): \(word(p.internetGotOut))")
        print("direct DNS (\(LeakTest.testAddress):53 through \(p.interface)): \(word(p.dnsGotOut))")
        print("direct IPv6 through \(p.interface): \(p.ipv6GotOut.map { $0 ? "GOT OUT" : "blocked" } ?? "no IPv6 on this card")")
        print("the normal way (through the VPN when it is up): \(reachesInternet() ? "works" : "no answer")")
        exit(0)
    }

    /// Does the test server answer the normal way (through the VPN when it is up)?
    static func reachesInternet() -> Bool {
        tcpConnects(to: LeakTest.testAddress, port: 443, interface: nil, timeout: 4) == true
    }

    /// True if a TCP connection was made, false if it was blocked or timed out, nil if the probe
    /// itself could not be set up (so the answer is unknown, never a silent "pass").
    static func tcpConnects(to host: String, port: UInt16, interface: String?, timeout: TimeInterval) -> Bool? {
        let v6 = host.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard bind(fd, to: interface, v6: v6) else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        guard let (result, code) = connect(fd, host: host, port: port, v6: v6) else { return nil }
        if result == 0 { return true }
        guard code == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }

    /// Asks the test server for apple.com over UDP port 53, straight through the card.
    static func dnsAnswers(server: String, interface: String, timeout: TimeInterval) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard bind(fd, to: interface, v6: false) else { return nil }
        guard let (result, _) = connect(fd, host: server, port: 53, v6: false) else { return nil }
        guard result == 0 else { return false }
        // Header (id, recursion wanted, 1 question) + "apple.com" + type A + class IN.
        var query: [UInt8] = [0x56, 0x47, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for part in ["apple", "com"] {
            query.append(UInt8(part.utf8.count))
            query.append(contentsOf: Array(part.utf8))
        }
        query.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        guard send(fd, query, query.count, 0) == query.count else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return false }
        var answer = [UInt8](repeating: 0, count: 512)
        return recv(fd, &answer, answer.count, 0) >= 12
    }

    /// An IPv6 address that is not link-local (fe80::/10) on this card.
    static func hasIPv6(interface: String) -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface, let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let bytes = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0.prefix(2)) }
            }
            if bytes.count == 2, !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
        }
        return false
    }

    /// Ties the socket to one network card (IP_BOUND_IF), so the VPN's routes do not apply.
    private static func bind(_ fd: Int32, to interface: String?, v6: Bool) -> Bool {
        guard let interface else { return true }
        var index = if_nametoindex(interface)
        guard index != 0 else { return false }
        let size = socklen_t(MemoryLayout<UInt32>.size)
        return v6 ? setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, size) == 0
                  : setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, size) == 0
    }

    /// connect(2); returns its result and errno, or nil if the address is not valid.
    private static func connect(_ fd: Int32, host: String, port: UInt16, v6: Bool) -> (Int32, Int32)? {
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, host, &a.sin6_addr) == 1 else { return nil }
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    let r = Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    return (r, errno)
                }
            }
        }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return nil }
        return withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                let r = Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                return (r, errno)
            }
        }
    }
}

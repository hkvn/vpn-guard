import Darwin
import Foundation
import VPNGuardCore

/// The ping of the quality window: an ICMP echo without root (a datagram ICMP socket, as macOS
/// allows), and if the network drops ICMP, the time a TCP connection to port 443 takes.
/// Blocking calls: run them off the main thread.
enum QualityProbe {
    /// Milliseconds, or nil when nothing answered within `timeout`.
    /// `interface`: tie the socket to that card, so it goes straight out, not through the VPN.
    static func ping(_ host: String, interface: String? = nil, timeout: TimeInterval = 1.5, tcpFallback: Bool = true) -> Double? {
        if let ms = icmp(host, interface: interface, timeout: timeout) { return ms }
        return tcpFallback ? tcp(host, port: 443, interface: interface, timeout: timeout) : nil
    }

    private static var sequence: UInt16 = 0
    private static let lock = NSLock()

    static func icmp(_ host: String, interface: String?, timeout: TimeInterval) -> Double? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard bindToInterface(fd, interface) else { return nil }

        lock.lock(); sequence &+= 1; let seq = sequence; lock.unlock()
        let ident = UInt16(truncatingIfNeeded: getpid())
        var packet: [UInt8] = [8, 0, 0, 0, UInt8(ident >> 8), UInt8(ident & 0xff), UInt8(seq >> 8), UInt8(seq & 0xff)]
        packet += Array("VPNGuard quality".utf8)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }
        let deadline = start + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32((deadline - now) / 1_000_000) + 1) > 0 else { return nil }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            // macOS hands datagram ICMP replies back with the IP header in front.
            var i = 0
            if buffer[0] >> 4 == 4 { i = Int(buffer[0] & 0x0f) * 4 }
            guard n >= i + 8 else { continue }
            let isReply = buffer[i] == 0
            let replySeq = UInt16(buffer[i + 6]) << 8 | UInt16(buffer[i + 7])
            if isReply && replySeq == seq {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
        }
    }

    /// How long a TCP connection takes (the handshake is one round trip).
    static func tcp(_ host: String, port: UInt16, interface: String?, timeout: TimeInterval) -> Double? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard bindToInterface(fd, interface) else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let start = DispatchTime.now().uptimeNanoseconds
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 {
            guard errno == EINPROGRESS else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func bindToInterface(_ fd: Int32, _ interface: String?) -> Bool {
        guard let interface else { return true }
        var index = if_nametoindex(interface)
        guard index != 0 else { return false }
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// `VPNGuard --ping <IPv4> [card]` prints 5 pings and exits (to check the probe).
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ping"), i + 1 < args.count else { return }
        let host = args[i + 1]
        let card = i + 2 < args.count ? args[i + 2] : nil
        var values: [Double?] = []
        for _ in 0..<5 {
            let icmpMs = icmp(host, interface: card, timeout: 1.5)
            let tcpMs = icmpMs == nil ? tcp(host, port: 443, interface: card, timeout: 1.5) : nil
            values.append(icmpMs ?? tcpMs)
            print(icmpMs.map { String(format: "icmp %.1f ms", $0) } ?? tcpMs.map { String(format: "tcp %.1f ms", $0) } ?? "no answer")
            usleep(300_000)
        }
        let s = PingStats(values)
        print(String(format: "median %.1f ms, jitter %.1f ms, loss %.0f %%, grade %@",
                     s.median ?? -1, s.jitter ?? -1, s.loss * 100, QualityGrade.of(s).title))
        exit(0)
    }
}

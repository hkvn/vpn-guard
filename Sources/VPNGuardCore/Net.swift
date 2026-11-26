import Foundation

/// Small validation helpers. Everything that ends up in pf rules goes through here.
public enum Net {
    public static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    /// `48:8F:5A:1:2:3` -> `48:8f:5a:01:02:03`. Returns nil for anything that is not a real unicast MAC.
    public static func normalizeMAC(_ s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: ":", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "-", omittingEmptySubsequences: false) }
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard (1...2).contains(p.count), let v = UInt8(p, radix: 16) else { return nil }
            bytes.append(v)
        }
        if bytes.allSatisfy({ $0 == 0 }) || bytes.allSatisfy({ $0 == 0xff }) { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    /// An address a tunnel can really use as its own: not 0.0.0.0/8, loopback, multicast or broadcast
    /// (IPv4), not ::, ::1 or multicast (IPv6). A config file with 0.0.0.0 was made before it was ready.
    public static func isUsableHostAddress(_ ip: String) -> Bool {
        if isIPv4(ip) {
            guard let first = ip.split(separator: ".").first.flatMap({ Int($0) }) else { return false }
            return first != 0 && first != 127 && first < 224
        }
        if isIPv6(ip) {
            var a = in6_addr()
            guard inet_pton(AF_INET6, ip, &a) == 1 else { return false }
            let b = withUnsafeBytes(of: &a) { Array($0) }
            let unspecified = b.allSatisfy { $0 == 0 }
            let loopback = b.dropLast().allSatisfy { $0 == 0 } && b.last == 1
            return !unspecified && !loopback && b[0] != 0xFF
        }
        return false
    }

    /// A macOS network service ID (a UUID such as 5F1D2C3A-9B7E-4A60-8D21-0C4E6F8A1B2D).
    public static func isServiceID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }

    /// Is the IPv4 address `ip` inside `cidr` (e.g. 192.0.2.1 in 192.0.2.0/24)? IPv4 only.
    public static func cidrContains(_ cidr: String, ip: String) -> Bool {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let net = ipv4Value(String(parts[0])), let addr = ipv4Value(ip) else { return false }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
        return net & mask == addr & mask
    }

    private static func ipv4Value(_ s: String) -> UInt32? {
        guard isIPv4(s) else { return nil }
        return s.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 }
    }

    /// 10.8.0.2/32 or fd00::2/128.
    public static func isCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]) else { return false }
        let ip = String(parts[0])
        if isIPv4(ip) { return (0...32).contains(bits) }
        if isIPv6(ip) { return (0...128).contains(bits) }
        return false
    }

    /// "10.8.0.2" -> "10.8.0.2/32"; anything else is returned as it is.
    public static func withPrefix(_ s: String) -> String {
        if isIPv4(s) { return s + "/32" }
        if isIPv6(s) { return s + "/128" }
        return s
    }

    /// A plain DNS name like `vpn.example.com` (lower case). Safe to use as a file name in /etc/resolver.
    public static func isHostName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, s.contains("."), !isIPv4(s) else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else { return false }
        }
        return !(labels.last?.allSatisfy(\.isNumber) ?? true)
    }

    /// BSD interface names are short ASCII letters and digits (en0, utun3, bridge100).
    public static func isValidInterfaceName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 15 && s.unicodeScalars.allSatisfy { ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x61 && $0.value <= 0x7a) }
    }

    public static func isLoopback(_ name: String) -> Bool { name.hasPrefix("lo") }

    private static let tunnelPrefixes = ["utun", "ppp", "ipsec", "tun", "tap", "wg"]

    public static func isTunnel(_ name: String) -> Bool {
        tunnelPrefixes.contains { name.hasPrefix($0) }
    }

    /// Interfaces whose packets never reach a real network directly: loopback, VPN tunnels,
    /// and the virtual bridges used by local VMs. Anything they send to the internet leaves
    /// through a real card later, and is filtered there. Thunderbolt Bridge (`bridge0`) is real.
    public static func isInternal(_ name: String) -> Bool {
        if isLoopback(name) || isTunnel(name) { return true }
        if name.hasPrefix("vmenet") { return true }
        if name.hasPrefix("bridge"), let n = Int(name.dropFirst("bridge".count)), n >= 100 { return true }
        return false
    }

    /// Resolves a host name to IPv4 addresses (blocking). Returns the input if it already is one.
    public static func resolveIPv4(_ host: String) -> [String] {
        let host = host.trimmingCharacters(in: .whitespaces)
        if isIPv4(host) { return [host] }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let sa = ai.pointee.ai_addr, ai.pointee.ai_family == AF_INET {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if !out.contains(ip) { out.append(ip) }
                }
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}

extension Array where Element: Hashable {
    /// Removes duplicates, keeps the first one.
    public func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Names people give to networks and VPNs.
public enum DisplayName {
    /// One line, no control characters, trimmed, at most 64 characters. Nil if nothing is left.
    public static func clean(_ raw: String) -> String? {
        let s = raw.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return String(s.prefix(64)).trimmingCharacters(in: .whitespaces)
    }
}


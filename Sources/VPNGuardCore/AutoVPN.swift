import Foundation

/// Decisions of the automatic VPN, kept pure so they can be tested.
public enum AutoVPN {
    /// How long a router may stay "resolving" (hardware address unknown) before we stop waiting
    /// and start the VPN anyway. Some links (USB modems, some tethering) never show one.
    public static let resolvingGrace: TimeInterval = 5

    /// Should the VPN be running for this state of the helper?
    /// `primaryTrusted`: with several networks (`mixed`), whether macOS sends traffic through a
    /// trusted one. Then no VPN is needed; through an untrusted one it is.
    public static func wantsVPN(mode: GuardMode, reason: GuardReason, resolvingFor: TimeInterval,
                                primaryTrusted: Bool = false) -> Bool {
        guard mode == .locked else { return false }
        switch reason {
        case .untrusted: return true
        case .mixed: return !primaryTrusted
        case .resolving: return resolvingFor >= resolvingGrace
        default: return false
        }
    }

    /// Protection off or paused means "normal internet": a VPN that VPN Guard started by itself is
    /// stopped then. One the user connected by hand stays on.
    public static func shouldStopOwnVPN(reason: GuardReason) -> Bool {
        reason == .disabled || reason == .paused
    }

    /// One physical network as a VPN sees it: card, our address, router.
    public static func linkKey(_ link: NetworkLink) -> String {
        "\(link.interface)|\(link.address ?? "")|\(link.routerIP)"
    }

    /// A PPP VPN (L2TP, PPTP) stays tied to the network and address it connected on. When none of
    /// those exist any more but another network is up, the tunnel is dead: macOS would only notice
    /// after up to 80 s. While there is no network at all we wait, because the same one may come back.
    public static func networkMovedAway(connectedOn: Set<String>, links: [NetworkLink]) -> Bool {
        guard !connectedOn.isEmpty, !links.isEmpty else { return false }
        return connectedOn.isDisjoint(with: links.map(linkKey))
    }

    /// VPN kinds that are tied to one network (macOS does not move them to a new one).
    public static func isPPP(kind: String) -> Bool { kind == "L2TP" || kind == "PPTP" }
}

/// The helper's allow list as the app keeps it.
public enum ServerList {
    /// Every server typed by hand stays. The servers of all VPNs (`wanted`, the chosen VPN first) are
    /// added, so switching VPN while locked never removes a server. Servers the app added earlier
    /// (`previousAuto`) are dropped only when no VPN uses them any more. Invalid values are skipped.
    /// The order of existing entries is kept, so an unchanged list is not sent again.
    public static func merge(current: [String], previousAuto: [String], wanted: [String],
                             limit: Int = 16) -> (list: [String], auto: [String]) {
        let clean = wanted.map(GuardConfig.normalizeServer)
            .filter { Net.isIPv4($0) || Net.isHostName($0) }
            .uniqued()
        let dropped = Set(previousAuto).subtracting(clean)
        var list = current.filter { !dropped.contains($0) }
        for s in clean where !list.contains(s) { list.append(s) }
        if list.count > limit {
            list = Array(list.prefix(limit))
            if let first = clean.first, !list.contains(first) { list[limit - 1] = first }
        }
        return (list, clean.filter(list.contains))
    }
}

extension GuardConfig {
    /// Looked-up IPs are a cache: a server that leaves the list (another VPN chosen) keeps its IP, so
    /// choosing it again while locked works at once. The cache is capped.
    public mutating func pruneHostCache(keepingAtMost limit: Int = 32) {
        guard hostIPs.count > limit else { return }
        let inUse = Set(serverHosts)
        let unused = hostIPs.keys.filter { !inUse.contains($0) }.sorted()
        for key in unused.prefix(hostIPs.count - limit) { hostIPs[key] = nil }
    }
}

extension GuardConfig {
    /// The trusted network a VPN's address ranges carry (its router is inside one of them), e.g.
    /// "Office" for a WireGuard tunnel with AllowedIPs 192.0.2.0/24. Nil if none.
    public func trustedNetworkName(carriedBy ranges: [String]) -> String? {
        trusted.first { t in
            guard let ip = t.routerIP else { return false }
            return ranges.contains { Net.cidrContains($0, ip: ip) }
        }?.name
    }
}

extension TrustedNetwork {
    /// Entries for trusting the networks in `candidates`: one per router, even when the Mac sees the
    /// same router over Wi-Fi and a cable. Links without a known router address are skipped.
    public static func newEntries(name: String, candidates: [NetworkLink]) -> [TrustedNetwork] {
        var seen = Set<String>()
        let unique = candidates.filter { link in
            guard let mac = link.routerMAC.flatMap(Net.normalizeMAC) else { return false }
            return seen.insert(mac).inserted
        }
        return unique.compactMap { link in
            guard let mac = link.routerMAC.flatMap(Net.normalizeMAC) else { return nil }
            let label = unique.count > 1 ? "\(name) (\(link.label))" : name
            return TrustedNetwork(name: label, routerMAC: mac, routerIP: link.routerIP)
        }
    }
}

// MARK: - Network loss and change (1.1.3)

/// The routers a pause was started on. A pause is for one place (a hotel login page): it must not
/// follow you to the next network.
public struct PausedNetwork: Codable, Equatable, Sendable {
    public var routerMACs: [String]
    public var routerIPs: [String]

    public init(links: [NetworkLink]) {
        routerMACs = links.compactMap { $0.routerMAC.flatMap(Net.normalizeMAC) }.uniqued()
        routerIPs = links.map(\.routerIP).uniqued()
    }

    /// Still the same place? No network at all (a Wi-Fi blip, sleep) keeps the pause. A router we
    /// know by its hardware address must be one of ours; one we don't know yet must have our IP.
    public func covers(_ links: [NetworkLink]) -> Bool {
        links.allSatisfy { link in
            if let mac = link.routerMAC.flatMap(Net.normalizeMAC) { return routerMACs.contains(mac) }
            return routerIPs.contains(link.routerIP)
        }
    }
}

extension AutoVPN {
    /// How long a network may be gone and still count as "the same one" when it comes back:
    /// your Connect / Disconnect choice survives a Wi-Fi blip or a short sleep.
    public static let sameNetworkGrace: TimeInterval = 600

    /// Is this a different place, so your Connect / Disconnect choice should be forgotten?
    /// `key` = the networks now (empty = none), `lastKey` = the last non-empty one,
    /// `goneFor` = how long there was no network just before (nil = it never went away).
    public static func isNewNetwork(key: String, lastKey: String, goneFor: TimeInterval?) -> Bool {
        if key.isEmpty { return false }          // no network: decide when one shows up
        if key != lastKey { return true }        // another router
        return (goneFor ?? 0) >= sameNetworkGrace // same router, but away for a long time
    }
}

/// Reading the routing table (output of macOS tools; parsed here so it can be tested).
public enum Routes {
    /// The system's main IPv4 default route from `netstat -rn -f inet`: the first `default` line
    /// that is not scoped to one card (no `I` flag) and does not go through a tunnel.
    public static func primaryDefault(netstat: String) -> (gateway: String, interface: String)? {
        for line in netstat.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, f[0] == "default", !f[2].contains("I"),
                  Net.isIPv4(f[1]), Net.isValidInterfaceName(f[3]), !Net.isTunnel(f[3]) else { continue }
            return (f[1], f[3])
        }
        return nil
    }

    /// The card in `route -n get <ip>` output ("  interface: en0").
    public static func interface(routeGet: String) -> String? {
        for line in routeGet.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("interface:") else { continue }
            let name = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return Net.isValidInterfaceName(name) ? name : nil
        }
        return nil
    }
}

// MARK: - Choosing which network to trust (1.2.0)

public enum TrustPick {
    /// Phone hotspots use fixed router addresses: iPhone 172.20.10.1, Android 192.168.43.1. A hotspot
    /// goes everywhere with its phone, so trusting it is risky.
    public static func isPhoneHotspot(_ link: NetworkLink) -> Bool {
        ["172.20.10.1", "192.168.43.1"].contains(link.routerIP)
    }

    /// The simple "give it a name" dialog is enough for one ordinary network. Several networks, or a
    /// phone hotspot, get the dialog where you tick what to trust.
    public static func needsPicker(_ candidates: [NetworkLink]) -> Bool {
        candidates.count > 1 || candidates.contains(where: isPhoneHotspot)
    }

    /// Ticked at first: only the network macOS uses, and never a phone hotspot (router addresses).
    public static func defaultTicks(_ candidates: [NetworkLink], primaryInterface: String?) -> Set<String> {
        guard let used = candidates.first(where: { $0.interface == primaryInterface }), !isPhoneHotspot(used),
              let mac = used.routerMAC.flatMap(Net.normalizeMAC) else { return [] }
        return [mac]
    }
}

// MARK: - NAT64 networks (1.2.1)

/// On an IPv6 network with NAT64 (many phone hotspots), macOS turns a server's IPv4 address into an
/// IPv6 one inside the network's NAT64 prefix (64:ff9b::c000:221 for 192.0.2.33). The lock must let
/// the VPN server through under that address too, or the VPN cannot connect.
public enum NAT64 {
    /// RFC 6052 section 2.2: the IPv4 address embedded in an IPv6 prefix of length 32, 40, 48, 56, 64
    /// or 96 (bits 64-71 stay zero). `prefix` is "64:ff9b::/96". Nil for anything invalid.
    public static func synthesize(ipv4: String, prefix: String) -> String? {
        let parts = prefix.split(separator: "/")
        guard parts.count == 2, let length = Int(parts[1]), [32, 40, 48, 56, 64, 96].contains(length),
              Net.isIPv4(ipv4) else { return nil }
        var v6 = in6_addr()
        var v4 = in_addr()
        guard inet_pton(AF_INET6, String(parts[0]), &v6) == 1, inet_pton(AF_INET, ipv4, &v4) == 1 else { return nil }
        var bytes = withUnsafeBytes(of: &v6) { Array($0) }
        let four = withUnsafeBytes(of: &v4) { Array($0) }
        // Where the four IPv4 bytes go for each prefix length (byte 8 is the zero "u" octet).
        let slots: [Int: [Int]] = [32: [4, 5, 6, 7], 40: [5, 6, 7, 9], 48: [6, 7, 9, 10],
                                   56: [7, 9, 10, 11], 64: [9, 10, 11, 12], 96: [12, 13, 14, 15]]
        for i in (length / 8)..<16 { bytes[i] = 0 }
        for (b, slot) in zip(four, slots[length]!) { bytes[slot] = b }
        var out = in6_addr()
        withUnsafeMutableBytes(of: &out) { $0.copyBytes(from: bytes) }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &out, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        let result = String(cString: text)
        return Net.isIPv6(result) ? result : nil
    }

    /// The IPv6 forms of all `servers` (IPv4) for all `prefixes`.
    public static func serverAddresses(_ servers: [String], prefixes: [String]) -> [String] {
        prefixes.flatMap { p in servers.compactMap { synthesize(ipv4: $0, prefix: p) } }.uniqued()
    }
}

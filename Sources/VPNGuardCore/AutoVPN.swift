import Foundation

/// Decisions of the automatic VPN, kept pure so they can be tested.
public enum AutoVPN {
    /// How long a router may stay "resolving" (hardware address unknown) before we stop waiting
    /// and start the VPN anyway. Some links (USB modems, some tethering) never show one.
    public static let resolvingGrace: TimeInterval = 5

    /// Should the VPN be running for this state of the helper?
    public static func wantsVPN(mode: GuardMode, reason: GuardReason, resolvingFor: TimeInterval) -> Bool {
        guard mode == .locked else { return false }
        switch reason {
        case .untrusted: return true
        case .resolving: return resolvingFor >= resolvingGrace
        default: return false
        }
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

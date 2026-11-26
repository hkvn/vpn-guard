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

import Foundation

public enum Policy {
    /// Decides open or locked. When in doubt, it locks.
    public static func decide(config: GuardConfig, links: [NetworkLink], now: Date) -> (mode: GuardMode, reason: GuardReason) {
        if !config.enabled { return (.open, .disabled) }
        if config.isPaused(at: now) { return (.open, .paused) }
        if links.isEmpty { return (.locked, .noNetwork) }
        let trusted = links.filter { $0.trustedName != nil }
        if trusted.count == links.count { return (.open, .trusted) }
        // Some cards trusted, others not (office Wi-Fi + iPhone USB): the trusted cards work as normal,
        // the others are locked to the VPN only (PFRules `openInterfaces`).
        if !trusted.isEmpty { return (.locked, .mixed) }
        // A known router that is not trusted settles it, even if another one is still unknown.
        if links.contains(where: { $0.routerMAC != nil }) { return (.locked, .untrusted) }
        return (.locked, .resolving)
    }
}

public enum PFRules {
    /// Tunnel names allowed even before they exist, so a VPN that comes up while
    /// locked works at once. Any other tunnel that shows up triggers a rebuild.
    public static let preallowedTunnels: [String] =
        (0..<16).map { "utun\($0)" } + (0..<4).map { "ppp\($0)" } + (0..<4).map { "ipsec\($0)" }

    /// Rules for lock mode. Only DHCP, a ping to the local router (to learn its MAC),
    /// and traffic to the VPN servers may use a real network card. Everything else,
    /// IPv6 included, is refused. Inputs are validated again here, so nothing odd can
    /// reach pfctl.
    /// `dnsLookupPort`: also let DNS out from that one source port. The helper adds it only for the
    /// second or two its own lookup runs (pf on macOS ignores `user root` here, so time is the guard).
    /// `refuse`: answer blocked apps at once (normal lock). `false` drops silently, for the short
    /// "no network / checking the router" phases, so a Wi-Fi blip does not kill SSH or calls.
    /// `openInterfaces`: trusted cards while another card is not (reason `mixed`): they work as normal.
    public static func lockRules(vpnServers: [String], routers: [String], interfaces: [String],
                                 dnsLookupPort: UInt16? = nil, refuse: Bool = true,
                                 openInterfaces: [String] = []) -> String {
        let servers = vpnServers.filter(Net.isIPv4).uniqued()
        let gateways = routers.filter(Net.isIPv4).uniqued()
        let insideMac = (["lo0"] + preallowedTunnels + interfaces.filter { Net.isValidInterfaceName($0) && Net.isInternal($0) }).uniqued()

        var r: [String] = []
        r.append("# VPN Guard lock rules. Generated, do not edit.")
        r.append("pass quick on { \(insideMac.joined(separator: " ")) } all no state")
        let open = openInterfaces.filter { Net.isValidInterfaceName($0) && !Net.isLoopback($0) && !Net.isTunnel($0) }.uniqued()
        if !open.isEmpty {
            r.append("pass quick on { \(open.joined(separator: " ")) } all no state")
        }
        r.append("pass out quick inet proto udp from any port 68 to any port 67 no state")
        r.append("pass in quick inet proto udp from any port 67 to any port 68 no state")
        if !gateways.isEmpty {
            r.append("pass out quick inet proto icmp from any to { \(gateways.joined(separator: " ")) } icmp-type echoreq keep state")
        }
        if let port = dnsLookupPort, port >= 1024 {
            r.append("pass out quick inet proto udp from any port \(port) to any port 53 keep state")
        }
        if !servers.isEmpty {
            let list = servers.joined(separator: " ")
            r.append("pass out quick inet from any to { \(list) } no state")
            r.append("pass in quick inet from { \(list) } to any no state")
        }
        r.append(refuse ? "block return out quick all" : "block drop out quick all")
        r.append("block drop in quick all")
        return r.joined(separator: "\n") + "\n"
    }
}

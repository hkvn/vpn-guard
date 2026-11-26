import Foundation

public enum Policy {
    /// Decides open or locked. When in doubt, it locks.
    public static func decide(config: GuardConfig, links: [NetworkLink], now: Date) -> (mode: GuardMode, reason: GuardReason) {
        if !config.enabled { return (.open, .disabled) }
        if config.isPaused(at: now) { return (.open, .paused) }
        if links.isEmpty { return (.locked, .noNetwork) }
        // A known router that is not trusted settles it, even if another one is still unknown.
        if links.contains(where: { $0.routerMAC != nil && $0.trustedName == nil }) { return (.locked, .untrusted) }
        if links.contains(where: { $0.routerMAC == nil }) { return (.locked, .resolving) }
        return (.open, .trusted)
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
    public static func lockRules(vpnServers: [String], routers: [String], interfaces: [String]) -> String {
        let servers = vpnServers.filter(Net.isIPv4).uniqued()
        let gateways = routers.filter(Net.isIPv4).uniqued()
        let insideMac = (["lo0"] + preallowedTunnels + interfaces.filter { Net.isValidInterfaceName($0) && Net.isInternal($0) }).uniqued()

        var r: [String] = []
        r.append("# VPN Guard lock rules. Generated, do not edit.")
        r.append("pass quick on { \(insideMac.joined(separator: " ")) } all no state")
        r.append("pass out quick inet proto udp from any port 68 to any port 67 no state")
        r.append("pass in quick inet proto udp from any port 67 to any port 68 no state")
        if !gateways.isEmpty {
            r.append("pass out quick inet proto icmp from any to { \(gateways.joined(separator: " ")) } icmp-type echoreq keep state")
        }
        if !servers.isEmpty {
            let list = servers.joined(separator: " ")
            r.append("pass out quick inet from any to { \(list) } no state")
            r.append("pass in quick inet from { \(list) } to any no state")
        }
        r.append("block return out quick all")
        r.append("block drop in quick all")
        return r.joined(separator: "\n") + "\n"
    }
}

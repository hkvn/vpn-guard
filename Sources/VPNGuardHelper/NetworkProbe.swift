import Foundation
import SystemConfiguration
import VPNGuardCore

/// Reads which networks the Mac is on, from the System Configuration dynamic store.
/// No processes are started and nothing is sent on the network.
enum NetworkProbe {
    static func links(store: SCDynamicStore?) -> [NetworkLink] {
        guard let store,
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]
        else { return [] }

        var byInterface: [String: NetworkLink] = [:]
        for key in keys {
            guard let d = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let ifname = d["InterfaceName"] as? String,
                  Net.isValidInterfaceName(ifname),
                  !Net.isLoopback(ifname), !Net.isTunnel(ifname),
                  let router = d["Router"] as? String, Net.isIPv4(router)
            else { continue }

            // configd already resolves the router's MAC for its "network signature".
            var mac: String?
            if (d["ARPResolvedIPAddress"] as? String) == router, let hw = d["ARPResolvedHardwareAddress"] as? String {
                mac = Net.normalizeMAC(hw)
            }
            let parts = key.split(separator: "/")
            let dnsKey = key.replacingOccurrences(of: "/IPv4", with: "/DNS") as CFString
            let dns = ((SCDynamicStoreCopyValue(store, dnsKey) as? [String: Any])?["ServerAddresses"] as? [String] ?? [])
                .filter { Net.isIPv4($0) || Net.isIPv6($0) }
            byInterface[ifname] = NetworkLink(
                interface: ifname,
                displayName: InterfaceNames.name(for: ifname),
                address: (d["Addresses"] as? [String])?.first,
                routerIP: router,
                routerMAC: mac,
                serviceID: parts.count >= 4 ? String(parts[3]) : nil,
                dnsServers: Array(dns.prefix(4))
            )
        }
        return byInterface.values.sorted { $0.interface < $1.interface }
    }

    /// NAT64 prefixes macOS found on these cards ("64:ff9b::/96"), from State:/Network/Interface/<if>/NAT64.
    static func nat64Prefixes(_ links: [NetworkLink], store: SCDynamicStore?) -> [String] {
        guard let store else { return [] }
        return links.flatMap { link -> [String] in
            let key = "State:/Network/Interface/\(link.interface)/NAT64" as CFString
            guard let d = SCDynamicStoreCopyValue(store, key) as? [String: Any],
                  let list = d["PrefixList"] as? [String] else { return [] }
            return list.filter { p in
                let parts = p.split(separator: "/")
                return parts.count == 2 && Net.isIPv6(String(parts[0])) && Int(parts[1]) != nil
            }
        }.uniqued()
    }

    /// The network macOS really uses for the internet. Not simply the first card by name: with
    /// Wi-Fi + cable, en0 may not be the one with the default route.
    static func primaryLink(_ links: [NetworkLink], store: SCDynamicStore?) -> NetworkLink? {
        guard !links.isEmpty else { return nil }
        // 1. The system default route, unless it goes through a tunnel (our own WireGuard).
        let table = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]).output
        if let d = Routes.primaryDefault(netstat: table), let l = links.first(where: { $0.interface == d.interface }) {
            return l
        }
        // 2. The user's service order in System Settings -> Network.
        if let store,
           let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let order = setup["ServiceOrder"] as? [String],
           let l = order.lazy.compactMap({ id in links.first { $0.serviceID == id } }).first {
            return l
        }
        return links.first
    }
}

/// "en0" -> "Wi-Fi", "en7" -> "iPhone USB", ...
enum InterfaceNames {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func name(for bsdName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let n = cache[bsdName] { return n }
        // Unknown card: reload the list once.
        var fresh: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                if let b = SCNetworkInterfaceGetBSDName(i) as String?,
                   let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                    fresh[b] = n
                }
            }
        }
        cache = fresh
        return fresh[bsdName]
    }
}

/// All interface names that exist right now.
enum Interfaces {
    static func names() -> [String] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var out: [String] = []
        var p = list
        while p.pointee.if_index != 0 {
            if let n = p.pointee.if_name { out.append(String(cString: n)) }
            p = p.advanced(by: 1)
        }
        return out
    }
}

/// Router MAC lookup in the kernel ARP table. Only a fallback: configd normally gives the MAC
/// (ARPResolvedHardwareAddress). The raw sysctl hides MACs from programs without Apple's
/// neighbor-cache entitlement, so we ask /usr/sbin/arp, which has it.
enum ARPTable {
    static func lookup(ip: String, interface: String) -> String? {
        guard Net.isIPv4(ip) else { return nil }
        // "? (192.168.1.1) at 48:8f:5a:1:2:3 on en0 ifscope [ethernet]"
        let r = Shell.run("/usr/sbin/arp", ["-n", ip])
        guard r.ok else { return nil }
        for line in r.output.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let at = words.firstIndex(of: "at"), at + 1 < words.count,
                  let on = words.firstIndex(of: "on"), on + 1 < words.count,
                  words[on + 1] == interface
            else { continue }
            if let mac = Net.normalizeMAC(words[at + 1]) { return mac }
        }
        return nil
    }
}

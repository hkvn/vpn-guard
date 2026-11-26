import Foundation
import SystemConfiguration
import VPNGuardCore

enum CLI {
    static let usage = """
    VPN Guard \(VG.version)

    Usage: vpnguard <command>

      status               Show the current state
      trust <name>         Trust the network you are on now (e.g. office, home)
      untrust <name|id>    Remove a trusted network
      pause <minutes>      Normal internet for a few minutes (café login pages)
      resume               End a pause
      enable | disable     Turn protection on or off
      servers [addr ...]   Set the VPN servers allowed through the firewall (IPs or host names)

    WireGuard (built in):
      wg list              Show WireGuard VPNs
      wg import <file> [name]   Add a WireGuard VPN from a .conf file
      wg up <name>         Connect
      wg down              Disconnect
      wg remove <name>     Remove

    Debug (no helper needed):
      detect               Show the networks and routers this Mac sees
      rules                Print the lock rules for the current networks
    """

    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 0
        }
        let rest = Array(args.dropFirst())
        switch command {
        case "status": return send(.status)
        case "refresh": return send(.refresh)
        case "trust":
            guard !rest.isEmpty else { return fail("Usage: vpnguard trust <name>") }
            return send(.trustCurrent(name: rest.joined(separator: " ")))
        case "untrust":
            guard let key = rest.first else { return fail("Usage: vpnguard untrust <name|id>") }
            return untrust(rest.count > 1 ? rest.joined(separator: " ") : key)
        case "pause":
            guard let m = rest.first.flatMap(Int.init) else { return fail("Usage: vpnguard pause <minutes>") }
            return send(.pause(minutes: m))
        case "resume": return send(.resume)
        case "enable": return send(.setEnabled(true))
        case "disable": return send(.setEnabled(false))
        case "servers":
            return rest.isEmpty ? send(.status) : send(.setVPNServers(rest))
        case "wg": return wireGuard(rest)
        case "detect": return detect()
        case "rules": return rules()
        case "help", "-h", "--help": print(usage); return 0
        default: return fail("Unknown command \"\(command)\".\n\n\(usage)")
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }

    private static func send(_ command: HelperCommand) -> Int32 {
        switch HelperClient().sendSync(command) {
        case .success(let status):
            print(describe(status))
            return 0
        case .failure(let error):
            return fail(error.localizedDescription)
        }
    }

    private static func untrust(_ key: String) -> Int32 {
        guard case .success(let status) = HelperClient().sendSync(.status) else { return send(.status) }
        let match = status.config.trusted.first {
            $0.id.uuidString.lowercased() == key.lowercased() || $0.name.lowercased() == key.lowercased()
        }
        guard let match else { return fail("No trusted network named \"\(key)\".") }
        return send(.untrust(id: match.id))
    }

    private static func wireGuard(_ args: [String]) -> Int32 {
        let client = HelperClient()
        func find(_ name: String) -> WireGuardTunnel? {
            guard case .success(let s) = client.sendSync(.status) else { return nil }
            return s.config.wireguard.first { $0.name.lowercased() == name.lowercased() || $0.id.uuidString.lowercased() == name.lowercased() }
        }
        switch args.first ?? "list" {
        case "list":
            return send(.status)
        case "import":
            guard args.count >= 2 else { return fail("Usage: vpnguard wg import <file.conf> [name]") }
            let path = args[1]
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return fail("Cannot read \(path).") }
            let name = args.count > 2 ? args[2...].joined(separator: " ") : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            do {
                let parsed = try WireGuardConf.parse(text, name: name)
                let code = send(.wgAdd(tunnel: parsed.tunnel, privateKey: parsed.privateKey, presharedKey: parsed.presharedKey))
                if code == 0 { print("Your public key: \(parsed.tunnel.publicKey)") }
                return code
            } catch {
                return fail(error.localizedDescription)
            }
        case "up":
            guard args.count >= 2 else { return fail("Usage: vpnguard wg up <name>") }
            guard let t = find(args[1...].joined(separator: " ")) else { return fail("No WireGuard VPN named \"\(args[1])\".") }
            return send(.wgConnect(id: t.id))
        case "down":
            return send(.wgDisconnect)
        case "remove":
            guard args.count >= 2 else { return fail("Usage: vpnguard wg remove <name>") }
            guard let t = find(args[1...].joined(separator: " ")) else { return fail("No WireGuard VPN named \"\(args[1])\".") }
            return send(.wgRemove(id: t.id))
        default:
            return fail("Unknown wg command.\n\n\(usage)")
        }
    }

    private static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    static func describe(_ s: GuardStatus) -> String {
        var lines: [String] = []
        let headline: String
        switch s.reason {
        case .disabled: headline = "Protection is OFF (normal internet everywhere)"
        case .paused: headline = "PAUSED until \(s.config.pausedUntil.map(timeString) ?? "?") (normal internet)"
        case .trusted: headline = "OPEN: trusted network"
        case .untrusted: headline = "LOCKED: untrusted network, only the VPN can connect"
        case .resolving: headline = "LOCKED: checking the router"
        case .noNetwork: headline = "LOCKED: no network"
        }
        lines.append(headline)
        for l in s.links {
            let trust = l.trustedName.map { "trusted as \"\($0)\"" } ?? "not trusted"
            lines.append("  \(l.label) (\(l.interface)): router \(l.routerIP) \(l.routerMAC ?? "MAC unknown"), \(trust)")
        }
        if let e = s.firewallError { lines.append("  Firewall problem: \(e)") }
        let servers = s.config.vpnServers.map { server -> String in
            if Net.isIPv4(server) { return server }
            let ips = s.config.hostIPs[server] ?? []
            return "\(server) -> \(ips.isEmpty ? "IP not known yet" : ips.joined(separator: ", "))"
        }
        lines.append("VPN servers allowed while locked: \(servers.isEmpty ? "(none)" : servers.joined(separator: "; "))")
        if s.config.allowedIPs.isEmpty && s.config.enabled {
            lines.append("  Warning: no VPN server IP is allowed, so the VPN cannot connect while locked.")
        }
        if !s.config.wireguard.isEmpty {
            lines.append("WireGuard VPNs:")
            for t in s.config.wireguard {
                var line = "  \(t.name): \(t.endpoint), address \(t.addresses.joined(separator: ", ")), your public key \(t.publicKey)"
                if let rt = s.wg, rt.tunnelID == t.id {
                    if rt.isConnected() {
                        line += "\n    CONNECTED on \(rt.interface ?? "?"), ↓ \(bytes(rt.rxBytes)) ↑ \(bytes(rt.txBytes))"
                    } else if rt.isRunning {
                        line += "\n    UP on \(rt.interface ?? "?"), waiting for the server to answer (↑ \(bytes(rt.txBytes)))"
                    } else {
                        line += "\n    CONNECTING"
                    }
                    if let e = rt.error { line += "\n    \(e)" }
                }
                lines.append(line)
            }
        }
        lines.append("Trusted networks:")
        if s.config.trusted.isEmpty { lines.append("  (none)") }
        for t in s.config.trusted {
            lines.append("  \(t.name): router \(t.routerMAC)\(t.routerIP.map { " (\($0))" } ?? "")")
        }
        if s.helperVersion != VG.version { lines.append("Helper version \(s.helperVersion), CLI version \(VG.version)") }
        return lines.joined(separator: "\n")
    }

    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: d)
    }

    private static func currentLinks() -> [NetworkLink] {
        let store = SCDynamicStoreCreate(nil, "vpnguard-cli" as CFString, nil, nil)
        var links = NetworkProbe.links(store: store)
        for i in links.indices where links[i].routerMAC == nil {
            links[i].routerMAC = ARPTable.lookup(ip: links[i].routerIP, interface: links[i].interface)
        }
        return links
    }

    private static func detect() -> Int32 {
        let links = currentLinks()
        if links.isEmpty { print("No network with a router.") }
        for l in links {
            print("\(l.label) (\(l.interface)): address \(l.address ?? "?"), router \(l.routerIP), router MAC \(l.routerMAC ?? "unknown")")
        }
        for l in links {
            print("arp fallback for \(l.routerIP): \(ARPTable.lookup(ip: l.routerIP, interface: l.interface) ?? "no entry")")
        }
        return 0
    }

    private static func rules() -> Int32 {
        let servers = ConfigStore().load().allowedIPs
        print(PFRules.lockRules(vpnServers: servers, routers: currentLinks().map(\.routerIP), interfaces: Interfaces.names()), terminator: "")
        return 0
    }
}

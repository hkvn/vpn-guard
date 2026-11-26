import Foundation
import SystemConfiguration
import VPNGuardCore

/// Private parts of a WireGuard VPN. Kept only in a root-only file.
struct WireGuardKeys: Codable {
    var privateKey: String
    var presharedKey: String?
}

struct WireGuardKeyStore {
    let path = VG.configDirectory + "/wireguard-keys.json"

    func load() -> [UUID: WireGuardKeys] {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? Wire.decode([String: WireGuardKeys].self, from: data) else { return [:] }
        var out: [UUID: WireGuardKeys] = [:]
        for (k, v) in raw { if let id = UUID(uuidString: k) { out[id] = v } }
        return out
    }

    /// Written with mode 0600 from the start (never readable by others, not even for a moment).
    func save(_ keys: [UUID: WireGuardKeys]) throws {
        var raw: [String: WireGuardKeys] = [:]
        for (k, v) in keys { raw[k.uuidString] = v }
        let data = Wire.encode(raw)
        try FileManager.default.createDirectory(atPath: VG.configDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let tmp = path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        close(fd)
        guard written == data.count, rename(tmp, path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Runs one WireGuard tunnel with the bundled wireguard-go (userspace, no Network Extension):
/// start the engine on a new utun, configure it over its control socket, add the addresses and
/// routes, and publish the tunnel to macOS (like the built-in VPNs do) so its DNS is used.
/// These are the same steps as wg-quick on macOS.
final class WireGuardManager {
    static let engine = "/Library/PrivilegedHelperTools/local.vpnguard.wireguard-go"
    static let runDir = "/var/run/wireguard"
    static let nameFile = runDir + "/vpnguard.name"
    static let stateServiceID = "VPNGuard-WireGuard"
    static let stateService = "State:/Network/Service/\(stateServiceID)"
    /// Original DNS settings we replaced, to put back after a crash.
    static let dnsBackup = "/var/run/vpnguard-dns.json"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let queue: DispatchQueue
    private var process: Process?
    private(set) var tunnelID: UUID?
    private(set) var interface: String?
    private(set) var startedAt: Date?
    private(set) var endpointIP: String?
    private var endpointGateway: String?
    /// The tunnel's DNS servers (full tunnel only).
    private var wantedDNS: [String] = []
    /// Service ID -> its DNS dictionary before we replaced it (nil = it had none).
    private var dnsOriginals: [String: [String: Any]?] = [:]

    /// Called on `queue` when wireguard-go stops by itself.
    var onExit: (() -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var isRunning: Bool { process?.isRunning == true && interface != nil }

    /// Removes leftovers from an earlier run (crash or update).
    func cleanUp(store: SCDynamicStore?) {
        restoreDNSFromBackup(store: store)
        removeState(store: store)
        unlink(Self.nameFile)
    }

    func up(_ t: WireGuardTunnel, keys: WireGuardKeys, endpointIP: String, gateway: String?, store: SCDynamicStore?) throws {
        down(store: store)
        guard FileManager.default.isExecutableFile(atPath: Self.engine) else {
            throw Failure(message: "The WireGuard engine is missing. Reinstall the helper.")
        }
        try? FileManager.default.createDirectory(atPath: Self.runDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        unlink(Self.nameFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.engine)
        p.arguments = ["-f", "utun"]
        var env = ProcessInfo.processInfo.environment
        env["WG_TUN_NAME_FILE"] = Self.nameFile
        env["LOG_LEVEL"] = "error"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            self?.queue.async {
                guard let self, proc === self.process else { return }
                self.process = nil
                self.interface = nil
                self.onExit?()
            }
        }
        do {
            try p.run()
        } catch {
            throw Failure(message: "The WireGuard engine did not start: \(error.localizedDescription)")
        }
        process = p

        // wireguard-go writes the utun name, then opens its control socket.
        var name: String?
        for _ in 0..<60 {
            if let n = try? String(contentsOfFile: Self.nameFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               Net.isValidInterfaceName(n), FileManager.default.fileExists(atPath: "\(Self.runDir)/\(n).sock") {
                name = n
                break
            }
            usleep(50_000)
        }
        guard let ifname = name else {
            down(store: store)
            throw Failure(message: "The WireGuard engine did not open its tunnel.")
        }
        interface = ifname
        self.endpointIP = endpointIP

        do {
            // Route to the server first, so even the first handshake leaves through the real network.
            updateEndpointRoute(gateway: gateway)
            try configure(ifname, t, keys: keys, endpointIP: endpointIP)
            try addAddresses(ifname, t)
            addRoutes(ifname, t)
            if t.isFullTunnel {
                publishState(ifname, t, endpointIP: endpointIP, store: store)
                wantedDNS = t.dns
                applyDNS(store: store)
            }
        } catch {
            down(store: store)
            throw error
        }
        tunnelID = t.id
        startedAt = Date()
    }

    func down(store: SCDynamicStore?) {
        if let p = process {
            process = nil
            if p.isRunning {
                p.terminate()
                for _ in 0..<40 where p.isRunning { usleep(50_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        if let ip = endpointIP, endpointGateway != nil {
            Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet", ip])
        }
        restoreDNS(store: store)
        removeState(store: store)
        unlink(Self.nameFile)
        interface = nil
        tunnelID = nil
        startedAt = nil
        endpointIP = nil
        endpointGateway = nil
    }

    /// The route to the server must go through the real network, not the tunnel. Keep it
    /// pointing at the current router when the Mac changes networks.
    func updateEndpointRoute(gateway: String?) {
        guard isRunning, let ip = endpointIP, gateway != endpointGateway else { return }
        if endpointGateway != nil { Shell.run("/sbin/route", ["-q", "-n", "delete", "-inet", ip]) }
        endpointGateway = nil
        if let gateway, Net.isIPv4(gateway) {
            Shell.run("/sbin/route", ["-q", "-n", "add", "-inet", ip, "-gateway", gateway])
            endpointGateway = gateway
        }
    }

    /// Handshake time and byte counters from the control socket.
    func stats() -> (handshake: Date?, rx: UInt64, tx: UInt64)? {
        guard isRunning, let ifname = interface,
              let reply = try? Self.uapi("\(Self.runDir)/\(ifname).sock", "get=1\n\n") else { return nil }
        var sec: TimeInterval = 0
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for line in reply.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "last_handshake_time_sec": sec = max(sec, TimeInterval(kv[1]) ?? 0)
            case "rx_bytes": rx += UInt64(kv[1]) ?? 0
            case "tx_bytes": tx += UInt64(kv[1]) ?? 0
            default: break
            }
        }
        return (sec > 0 ? Date(timeIntervalSince1970: sec) : nil, rx, tx)
    }

    // MARK: - Steps

    private func configure(_ ifname: String, _ t: WireGuardTunnel, keys: WireGuardKeys, endpointIP: String) throws {
        guard let priv = WireGuardKey.hex(keys.privateKey), let peer = WireGuardKey.hex(t.peerPublicKey) else {
            throw Failure(message: "A WireGuard key is not valid.")
        }
        var lines = ["set=1", "private_key=\(priv)", "replace_peers=true", "public_key=\(peer)"]
        if let psk = keys.presharedKey, let hex = WireGuardKey.hex(psk) { lines.append("preshared_key=\(hex)") }
        lines.append("endpoint=\(endpointIP):\(t.endpointPort)")
        lines.append("persistent_keepalive_interval=\(t.keepalive ?? 25)")
        lines.append("replace_allowed_ips=true")
        lines += t.allowedIPs.filter(Net.isCIDR).map { "allowed_ip=\($0)" }
        let reply = try Self.uapi("\(Self.runDir)/\(ifname).sock", lines.joined(separator: "\n") + "\n\n")
        guard reply.contains("errno=0") else {
            throw Failure(message: "The WireGuard engine refused the settings (\(reply.trimmingCharacters(in: .whitespacesAndNewlines))).")
        }
    }

    private func addAddresses(_ ifname: String, _ t: WireGuardTunnel) throws {
        for cidr in t.addresses where Net.isCIDR(cidr) {
            let ip = String(cidr.split(separator: "/")[0])
            let r = Net.isIPv4(ip)
                ? Shell.run("/sbin/ifconfig", [ifname, "inet", cidr, ip, "alias"])
                : Shell.run("/sbin/ifconfig", [ifname, "inet6", cidr, "alias"])
            if !r.ok { throw Failure(message: "Could not set the tunnel address \(cidr): \(r.output)") }
        }
        Shell.run("/sbin/ifconfig", [ifname, "mtu", String(t.mtu ?? 1420)])
        Shell.run("/sbin/ifconfig", [ifname, "up"])
    }

    private func addRoutes(_ ifname: String, _ t: WireGuardTunnel) {
        var routes: [(String, String)] = []
        for cidr in t.allowedIPs where Net.isCIDR(cidr) {
            switch cidr {
            case "0.0.0.0/0": routes += [("-inet", "0.0.0.0/1"), ("-inet", "128.0.0.0/1")]
            case "::/0": routes += [("-inet6", "::/1"), ("-inet6", "8000::/1")]
            default: routes.append((cidr.contains(":") ? "-inet6" : "-inet", cidr))
            }
        }
        for (family, cidr) in routes {
            Shell.run("/sbin/route", ["-q", "-n", "add", family, cidr, "-interface", ifname])
        }
    }

    /// Publishes the tunnel the way macOS VPNs do (see State:/Network/Service/<id>/IPv4 and DNS
    /// of an L2TP VPN): OverridePrimary makes it the primary service, so its DNS servers are used.
    private func publishState(_ ifname: String, _ t: WireGuardTunnel, endpointIP: String, store: SCDynamicStore?) {
        guard let store else { return }
        let v4 = t.addresses.filter { Net.isCIDR($0) && !$0.contains(":") }.map { String($0.split(separator: "/")[0]) }
        var ipv4: [String: Any] = [
            "InterfaceName": ifname,
            "OverridePrimary": 1,
            "ServerAddress": endpointIP,
        ]
        if let first = v4.first {
            ipv4["Addresses"] = v4
            ipv4["DestAddresses"] = v4
            ipv4["Router"] = first
        }
        var values: [String: Any] = ["\(Self.stateService)/IPv4": ipv4]
        if !t.dns.isEmpty {
            values["\(Self.stateService)/DNS"] = [
                "ServerAddresses": t.dns,
                "SupplementalMatchDomains": [""],
                "SupplementalMatchOrders": [100000],
            ] as [String: Any]
        }
        SCDynamicStoreSetMultiple(store, values as CFDictionary, nil, nil)
    }

    /// Puts the tunnel's DNS servers on the service macOS uses as primary (another VPN, or Wi‑Fi).
    /// Called after every network change while the tunnel is up, because DHCP rewrites them.
    func applyDNS(store: SCDynamicStore?) {
        guard let store, isRunning, !wantedDNS.isEmpty,
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryService"] as? String,
              primary != Self.stateServiceID,
              !primary.contains("/")
        else { return }
        let key = "State:/Network/Service/\(primary)/DNS"
        let current = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        if (current?["ServerAddresses"] as? [String]) == wantedDNS { return }
        // Whatever macOS just published is the newest original.
        dnsOriginals[primary] = .some(current)
        var ours: [String: Any] = ["ServerAddresses": wantedDNS]
        if let match = current?["SupplementalMatchDomains"] { ours["SupplementalMatchDomains"] = match }
        if let order = current?["SupplementalMatchOrders"] { ours["SupplementalMatchOrders"] = order }
        SCDynamicStoreSetValue(store, key as CFString, ours as CFDictionary)
        saveDNSBackup()
        Log.info("DNS of \(primary) set to \(wantedDNS.joined(separator: ", ")) while WireGuard is on")
    }

    private func restoreDNS(store: SCDynamicStore?) {
        wantedDNS = []
        guard let store else { return }
        for (service, original) in dnsOriginals {
            let key = "State:/Network/Service/\(service)/DNS" as CFString
            if let original { SCDynamicStoreSetValue(store, key, original as CFDictionary) } else { SCDynamicStoreRemoveValue(store, key) }
        }
        if !dnsOriginals.isEmpty { Log.info("DNS restored") }
        dnsOriginals = [:]
        unlink(Self.dnsBackup)
    }

    private func saveDNSBackup() {
        var plain: [String: Any] = [:]
        for (service, original) in dnsOriginals { plain[service] = original ?? NSNull() }
        if let data = try? JSONSerialization.data(withJSONObject: plain) {
            try? data.write(to: URL(fileURLWithPath: Self.dnsBackup), options: .atomic)
        }
    }

    private func restoreDNSFromBackup(store: SCDynamicStore?) {
        guard let store, let data = FileManager.default.contents(atPath: Self.dnsBackup),
              let plain = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (service, original) in plain where !service.contains("/") {
            let key = "State:/Network/Service/\(service)/DNS" as CFString
            if let dict = original as? [String: Any] { SCDynamicStoreSetValue(store, key, dict as CFDictionary) } else { SCDynamicStoreRemoveValue(store, key) }
        }
        unlink(Self.dnsBackup)
        Log.info("DNS restored after a restart")
    }

    private func removeState(store: SCDynamicStore?) {
        guard let store else { return }
        SCDynamicStoreSetMultiple(store, nil, ["\(Self.stateService)/IPv4", "\(Self.stateService)/DNS"] as CFArray, nil)
    }

    // MARK: - Control socket (cross-platform UAPI of WireGuard)

    static func uapi(_ socketPath: String, _ request: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "Cannot open the WireGuard control socket.") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure(message: "Socket path too long.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path)
            buf[path.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure(message: "Cannot reach the WireGuard engine.") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw Failure(message: "Lost the WireGuard engine.") }
            sent += n
        }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
            if out.count >= 2 && out[out.count - 2] == 10 && out[out.count - 1] == 10 { break }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

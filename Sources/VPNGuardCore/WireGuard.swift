import CryptoKit
import Foundation

/// WireGuard keys: 32 bytes, base64.
public enum WireGuardKey {
    /// A new private key (clamped like `wg genkey`).
    public static func generatePrivate() -> String {
        var bytes = [UInt8](Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        bytes[0] &= 248
        bytes[31] = (bytes[31] & 127) | 64
        return Data(bytes).base64EncodedString()
    }

    public static func decode(_ key: String) -> Data? {
        guard let data = Data(base64Encoded: key.trimmingCharacters(in: .whitespaces)), data.count == 32 else { return nil }
        return data
    }

    public static func isValid(_ key: String) -> Bool { decode(key) != nil }

    public static func publicKey(fromPrivate key: String) -> String? {
        guard let raw = decode(key),
              let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        return priv.publicKey.rawRepresentation.base64EncodedString()
    }

    /// The hex form the wireguard-go control socket wants.
    public static func hex(_ key: String) -> String? {
        decode(key).map { $0.map { String(format: "%02x", $0) }.joined() }
    }
}

/// One WireGuard VPN, without its secrets. The private key and the pre-shared key live only in
/// the helper's root-only key file.
public struct WireGuardTunnel: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// This Mac's public key (from the private key), to give to the server.
    public var publicKey: String
    /// This Mac's address inside the VPN, e.g. 10.8.0.2/32.
    public var addresses: [String]
    public var dns: [String]
    public var mtu: Int?
    public var peerPublicKey: String
    /// Server, as host:port.
    public var endpoint: String
    public var allowedIPs: [String]
    public var keepalive: Int?
    public var hasPresharedKey: Bool

    public init(id: UUID = UUID(), name: String, publicKey: String, addresses: [String], dns: [String], mtu: Int? = nil,
                peerPublicKey: String, endpoint: String, allowedIPs: [String] = ["0.0.0.0/0", "::/0"],
                keepalive: Int? = 25, hasPresharedKey: Bool = false) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.addresses = addresses
        self.dns = dns
        self.mtu = mtu
        self.peerPublicKey = peerPublicKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.keepalive = keepalive
        self.hasPresharedKey = hasPresharedKey
    }

    /// (host, port), or nil if the endpoint is not "host:port" with an IPv4 address or host name.
    public static func splitEndpoint(_ endpoint: String) -> (host: String, port: Int)? {
        let e = endpoint.trimmingCharacters(in: .whitespaces)
        guard let colon = e.lastIndex(of: ":"), !e.hasPrefix("[") else { return nil }
        let host = GuardConfig.normalizeServer(String(e[..<colon]))
        guard let port = Int(e[e.index(after: colon)...]), (1...65535).contains(port),
              Net.isIPv4(host) || Net.isHostName(host) else { return nil }
        return (host, port)
    }

    public var endpointHost: String { Self.splitEndpoint(endpoint)?.host ?? "" }
    public var endpointPort: Int { Self.splitEndpoint(endpoint)?.port ?? 0 }
    public var isFullTunnel: Bool { allowedIPs.contains("0.0.0.0/0") }

    /// Everything wrong with this tunnel, in plain words. Empty = OK.
    public func problems() -> [String] {
        var p: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Give the VPN a name.") }
        if Self.splitEndpoint(endpoint) == nil {
            p.append("The server must look like vpn.example.com:51820 or 203.0.113.10:51820.")
        }
        if !WireGuardKey.isValid(peerPublicKey) { p.append("The server public key is not a WireGuard key (44 characters, ends with =).") }
        if addresses.isEmpty { p.append("Enter your address in the VPN, e.g. 10.8.0.2/32.") }
        if let bad = addresses.first(where: { !Net.isCIDR($0) }) { p.append("\"\(bad)\" is not an address like 10.8.0.2/32.") }
        if let bad = dns.first(where: { !Net.isIPv4($0) && !Net.isIPv6($0) }) { p.append("\"\(bad)\" is not a DNS server IP address.") }
        if allowedIPs.isEmpty || allowedIPs.contains(where: { !Net.isCIDR($0) }) { p.append("Allowed IPs must be addresses like 0.0.0.0/0.") }
        if let mtu, !(1280...1500).contains(mtu) { p.append("MTU must be between 1280 and 1500.") }
        if let keepalive, !(0...600).contains(keepalive) { p.append("Keepalive must be 0 to 600 seconds.") }
        return p
    }

    /// Command to add this Mac as a peer on a MikroTik (RouterOS 7) router.
    public func mikrotikCommand(interface: String = "wireguard1") -> String {
        let address = addresses.first ?? "10.8.0.2/32"
        let label = name.trimmingCharacters(in: .whitespaces).filter { $0 != "\"" && $0 != "\\" }
        let comment = label.isEmpty ? "VPN Guard" : "VPN Guard \(label)"
        return "/interface wireguard peers add interface=\(interface) \\\n  public-key=\"\(publicKey)\" \\\n  allowed-address=\(address) comment=\"\(comment)\""
    }
}

/// What the helper reports about the running tunnel.
public struct WireGuardRuntime: Codable, Equatable, Sendable {
    public var tunnelID: UUID
    public var interface: String?
    public var startedAt: Date?
    public var lastHandshake: Date?
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var error: String?

    public init(tunnelID: UUID, interface: String? = nil, startedAt: Date? = nil, lastHandshake: Date? = nil,
                rxBytes: UInt64 = 0, txBytes: UInt64 = 0, error: String? = nil) {
        self.tunnelID = tunnelID
        self.interface = interface
        self.startedAt = startedAt
        self.lastHandshake = lastHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.error = error
    }

    public var isRunning: Bool { interface != nil }

    /// A handshake in the last 3 minutes means the server answers.
    public func isConnected(at now: Date = Date()) -> Bool {
        guard isRunning, let h = lastHandshake else { return false }
        return now.timeIntervalSince(h) < 180
    }

    /// Same tunnel and state, ignoring the byte counters (they change all the time).
    public var withoutCounters: WireGuardRuntime {
        var copy = self
        copy.rxBytes = 0
        copy.txBytes = 0
        copy.lastHandshake = lastHandshake.map { _ in Date(timeIntervalSince1970: 0) }
        return copy
    }
}

/// Reads a wg-quick style .conf file (one [Interface], one [Peer]).
public enum WireGuardConf {
    public struct Parsed: Equatable, Sendable {
        public var tunnel: WireGuardTunnel
        public var privateKey: String
        public var presharedKey: String?
    }

    public struct ParseError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ text: String, name: String) throws -> Parsed {
        var section = ""
        var interface: [String: String] = [:]
        var peer: [String: String] = [:]
        var peers = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(where: { $0 == "#" || $0 == ";" }) { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                if section == "peer" { peers += 1 }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "interface": interface[key] = interface[key].map { "\($0), \(value)" } ?? value
            case "peer": peer[key] = peer[key].map { "\($0), \(value)" } ?? value
            default: continue
            }
        }
        guard !interface.isEmpty else { throw ParseError(message: "This is not a WireGuard file: no [Interface] section.") }
        guard peers == 1 else {
            throw ParseError(message: peers == 0 ? "The file has no [Peer] section." : "Only one [Peer] is supported.")
        }
        guard let privateKey = interface["privatekey"], WireGuardKey.isValid(privateKey),
              let publicKey = WireGuardKey.publicKey(fromPrivate: privateKey) else {
            throw ParseError(message: "The file has no valid PrivateKey.")
        }
        let list: (String?) -> [String] = { value in
            (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let preshared = peer["presharedkey"]
        if let preshared, !WireGuardKey.isValid(preshared) { throw ParseError(message: "The PresharedKey is not valid.") }

        let allowed = list(peer["allowedips"])
        let tunnel = WireGuardTunnel(
            name: name.trimmingCharacters(in: .whitespaces),
            publicKey: publicKey,
            addresses: list(interface["address"]).map(Net.withPrefix),
            dns: list(interface["dns"]).filter { Net.isIPv4($0) || Net.isIPv6($0) },
            mtu: interface["mtu"].flatMap { Int($0) },
            peerPublicKey: peer["publickey"] ?? "",
            endpoint: peer["endpoint"] ?? "",
            allowedIPs: allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed,
            keepalive: peer["persistentkeepalive"].flatMap { Int($0) },
            hasPresharedKey: preshared != nil
        )
        if let problem = tunnel.problems().first { throw ParseError(message: problem) }
        return Parsed(tunnel: tunnel, privateKey: privateKey, presharedKey: preshared)
    }
}

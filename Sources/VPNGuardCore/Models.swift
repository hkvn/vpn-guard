import Foundation

/// A network the user trusts, identified by its router's MAC address.
public struct TrustedNetwork: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Normalized form: lower case, `aa:bb:cc:dd:ee:ff`.
    public var routerMAC: String
    public var routerIP: String?
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, routerMAC: String, routerIP: String?, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.routerMAC = routerMAC
        self.routerIP = routerIP
        self.addedAt = addedAt
    }
}

/// Stored by the helper in /Library/Application Support/VPNGuard/config.json (root only).
public struct GuardConfig: Codable, Equatable, Sendable {
    /// Master switch. Off on a fresh install, so installing never cuts the internet.
    public var enabled: Bool
    /// VPN servers that may be reached outside the VPN: IPv4 addresses or host names.
    public var vpnServers: [String]
    /// Last good DNS answer for each host name in `vpnServers`. Answered locally (PinnedDNS), because
    /// DNS is blocked while locked and the VPN client must still find its server.
    public var hostIPs: [String: [String]]
    public var trusted: [TrustedNetwork]
    public var pausedUntil: Date?
    /// The routers seen when the pause started. Joining any other router ends the pause.
    public var pausedOn: PausedNetwork?
    /// Built-in WireGuard VPNs (no secrets here).
    public var wireguard: [WireGuardTunnel]
    /// The WireGuard VPN the helper should keep up, if any.
    public var wgActive: UUID?

    public init(enabled: Bool = false, vpnServers: [String] = [], hostIPs: [String: [String]] = [:],
                trusted: [TrustedNetwork] = [], pausedUntil: Date? = nil,
                wireguard: [WireGuardTunnel] = [], wgActive: UUID? = nil) {
        self.enabled = enabled
        self.vpnServers = vpnServers
        self.hostIPs = hostIPs
        self.trusted = trusted
        self.pausedUntil = pausedUntil
        self.wireguard = wireguard
        self.wgActive = wgActive
    }

    // Tolerant decoding: missing keys get defaults, so old config files keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        vpnServers = try c.decodeIfPresent([String].self, forKey: .vpnServers) ?? []
        hostIPs = try c.decodeIfPresent([String: [String]].self, forKey: .hostIPs) ?? [:]
        trusted = try c.decodeIfPresent([TrustedNetwork].self, forKey: .trusted) ?? []
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        pausedOn = try c.decodeIfPresent(PausedNetwork.self, forKey: .pausedOn)
        wireguard = try c.decodeIfPresent([WireGuardTunnel].self, forKey: .wireguard) ?? []
        wgActive = try c.decodeIfPresent(UUID.self, forKey: .wgActive)
    }

    /// Every server host the firewall must let through: the VPN servers and the WireGuard endpoints.
    public var serverHosts: [String] {
        (vpnServers + wireguard.map(\.endpointHost)).filter { !$0.isEmpty }.uniqued()
    }

    /// IPv4 addresses the firewall lets through while locked.
    public var allowedIPs: [String] {
        serverHosts
            .flatMap { Net.isIPv4($0) ? [$0] : (hostIPs[$0] ?? []) }
            .filter(Net.isIPv4)
            .uniqued()
    }

    /// "VPN.Example.com." -> "vpn.example.com"
    public static func normalizeServer(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.hasSuffix(".") { v.removeLast() }
        return v
    }

    public func trustedNetwork(matchingMAC mac: String?) -> TrustedNetwork? {
        guard let mac = mac.flatMap(Net.normalizeMAC) else { return nil }
        return trusted.first { $0.routerMAC == mac }
    }

    public func isPaused(at now: Date) -> Bool {
        guard let until = pausedUntil else { return false }
        return until > now
    }
}

/// One active network card that has a router (Wi-Fi, Ethernet, iPhone USB, ...).
public struct NetworkLink: Codable, Hashable, Sendable {
    public var interface: String
    public var displayName: String?
    public var address: String?
    public var routerIP: String
    public var routerMAC: String?
    public var trustedName: String?
    /// configd service ID (to find the network macOS prefers, from the service order).
    public var serviceID: String?

    public init(interface: String, displayName: String? = nil, address: String? = nil,
                routerIP: String, routerMAC: String? = nil, trustedName: String? = nil, serviceID: String? = nil) {
        self.serviceID = serviceID
        self.interface = interface
        self.displayName = displayName
        self.address = address
        self.routerIP = routerIP
        self.routerMAC = routerMAC
        self.trustedName = trustedName
    }

    public var label: String { displayName ?? interface }
}

public enum GuardMode: String, Codable, Sendable {
    /// Normal internet.
    case open
    /// Only the VPN can leave the Mac.
    case locked
}

public enum GuardReason: String, Codable, Sendable {
    case disabled    // protection switched off
    case paused      // paused for a few minutes
    case trusted     // every active network is trusted
    case untrusted   // at least one active network is not trusted
    case resolving   // router MAC not known yet (locked while we look)
    case noNetwork   // no network with a router
}

public struct GuardStatus: Codable, Equatable, Sendable {
    public var mode: GuardMode
    public var reason: GuardReason
    public var links: [NetworkLink]
    public var config: GuardConfig
    public var firewallError: String?
    public var helperVersion: String
    public var updatedAt: Date
    /// The WireGuard tunnel the helper runs (or tried to run).
    public var wg: WireGuardRuntime?

    public init(mode: GuardMode, reason: GuardReason, links: [NetworkLink], config: GuardConfig,
                firewallError: String?, helperVersion: String, updatedAt: Date, wg: WireGuardRuntime? = nil) {
        self.mode = mode
        self.reason = reason
        self.links = links
        self.config = config
        self.firewallError = firewallError
        self.helperVersion = helperVersion
        self.updatedAt = updatedAt
        self.wg = wg
    }
}

/// Requests from the app / CLI to the helper.
public enum HelperCommand: Codable, Sendable {
    case status
    case refresh
    case trustCurrent(name: String)
    case untrust(id: UUID)
    case rename(id: UUID, name: String)
    case pause(minutes: Int)
    case resume
    case setEnabled(Bool)
    case setVPNServers([String])
    /// Look up the VPN server names again now (the app asks after a VPN failed to connect).
    case lookUpServers
    case wgAdd(tunnel: WireGuardTunnel, privateKey: String, presharedKey: String?)
    case wgRemove(id: UUID)
    case wgConnect(id: UUID)
    case wgDisconnect
}

public struct HelperReply: Codable, Sendable {
    public var status: GuardStatus?
    public var error: String?

    public init(status: GuardStatus? = nil, error: String? = nil) {
        self.status = status
        self.error = error
    }
}

/// JSON used on the XPC wire and in the config file.
public enum Wire {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

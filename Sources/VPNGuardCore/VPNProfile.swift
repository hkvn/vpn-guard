import Foundation

/// What the user types to create a macOS VPN. Turned into an Apple configuration profile
/// (.mobileconfig) that the user approves once in System Settings. macOS then owns the VPN:
/// it keeps the password and secret in the System keychain and runs the connection.
public struct VPNProfileDraft: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case l2tp, ikev2
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .l2tp: return "L2TP over IPSec"
            case .ikev2: return "IKEv2"
            }
        }
    }

    public var kind: Kind = .l2tp
    public var name = ""
    public var server = ""
    public var account = ""
    public var password = ""
    public var sharedSecret = ""
    /// IKEv2 only. Empty = the server address.
    public var remoteID = ""
    /// IKEv2 only, optional.
    public var localID = ""
    /// Optional DNS servers used while the VPN is on, separated by commas or spaces.
    public var dnsServers = ""

    public init() {}

    public var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var cleanServer: String { GuardConfig.normalizeServer(server) }

    public var dnsList: [String] {
        dnsServers.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Everything that stops the profile from being made, in plain words. Empty = OK.
    public func problems() -> [String] {
        var p: [String] = []
        if cleanName.isEmpty { p.append("Give the VPN a name.") }
        if cleanName.count > 60 { p.append("Use a name of 60 characters or fewer.") }
        if cleanServer.isEmpty {
            p.append("Enter the server address.")
        } else if !Net.isIPv4(cleanServer) && !Net.isHostName(cleanServer) {
            p.append("The server must be an IP address or a host name, like 203.0.113.10 or vpn.example.com.")
        }
        switch kind {
        case .l2tp:
            if account.trimmingCharacters(in: .whitespaces).isEmpty { p.append("Enter the account name.") }
            if sharedSecret.isEmpty { p.append("L2TP needs the shared secret (the IPSec pre-shared key).") }
        case .ikev2:
            if sharedSecret.isEmpty && account.trimmingCharacters(in: .whitespaces).isEmpty {
                p.append("IKEv2 needs a shared secret, or an account and password.")
            }
            if !account.isEmpty && password.isEmpty { p.append("Enter the password for the account.") }
        }
        if let bad = dnsList.first(where: { !Net.isIPv4($0) && !Net.isIPv6($0) }) {
            p.append("\"\(bad)\" is not a DNS server IP address.")
        }
        return p
    }

    /// The .mobileconfig file contents (XML property list).
    public func mobileconfig(profileUUID: UUID = UUID(), payloadUUID: UUID = UUID()) throws -> Data {
        let name = cleanName
        let server = cleanServer
        var vpn: [String: Any] = [
            "PayloadType": "com.apple.vpn.managed",
            "PayloadIdentifier": "\(VG.appBundleID).profile.\(profileUUID.uuidString).vpn",
            "PayloadUUID": payloadUUID.uuidString,
            "PayloadVersion": 1,
            "PayloadDisplayName": "VPN (\(name))",
            "UserDefinedName": name,
            // "Send all traffic over VPN connection": always on. VPN Guard depends on it.
            "IPv4": ["OverridePrimary": 1],
        ]
        switch kind {
        case .l2tp:
            vpn["VPNType"] = "L2TP"
            var ppp: [String: Any] = [
                "CommRemoteAddress": server,
                "AuthName": account.trimmingCharacters(in: .whitespaces),
                "TokenCard": false,
            ]
            if !password.isEmpty { ppp["AuthPassword"] = password }
            vpn["PPP"] = ppp
            vpn["IPSec"] = [
                "AuthenticationMethod": "SharedSecret",
                "LocalIdentifierType": "KeyID",
                "SharedSecret": Data(sharedSecret.utf8),
            ] as [String: Any]
        case .ikev2:
            vpn["VPNType"] = "IKEv2"
            let remote = remoteID.trimmingCharacters(in: .whitespaces)
            var ike: [String: Any] = [
                "RemoteAddress": server,
                "RemoteIdentifier": remote.isEmpty ? server : remote,
                "AuthenticationMethod": sharedSecret.isEmpty ? "None" : "SharedSecret",
                "DeadPeerDetectionRate": "Medium",
            ]
            let local = localID.trimmingCharacters(in: .whitespaces)
            if !local.isEmpty { ike["LocalIdentifier"] = local }
            if !sharedSecret.isEmpty { ike["SharedSecret"] = sharedSecret }
            let user = account.trimmingCharacters(in: .whitespaces)
            if !user.isEmpty {
                ike["ExtendedAuthEnabled"] = 1
                ike["AuthName"] = user
                if !password.isEmpty { ike["AuthPassword"] = password }
            }
            vpn["IKEv2"] = ike
        }
        let dns = dnsList
        if !dns.isEmpty { vpn["DNS"] = ["ServerAddresses": dns] }

        let profile: [String: Any] = [
            "PayloadContent": [vpn],
            "PayloadDisplayName": "VPN Guard: \(name)",
            "PayloadDescription": "Adds the VPN \"\(name)\" (\(kind.title), server \(server)). All traffic goes through it. Made by VPN Guard on this Mac.",
            "PayloadIdentifier": "\(VG.appBundleID).profile.\(profileUUID.uuidString)",
            "PayloadOrganization": "VPN Guard",
            "PayloadType": "Configuration",
            "PayloadUUID": profileUUID.uuidString,
            "PayloadVersion": 1,
            "PayloadScope": "System",
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

import Foundation

/// Decides which programs may control the root helper over XPC.
///
/// - Signed with a team (Apple Development / Developer ID): same team and one of our identifiers.
/// - Ad-hoc signed (no team, e.g. the free DMG): identifiers alone could be copied by any local
///   program, so we pin exact code hashes instead: the helper's own (for the `vpnguard` CLI) and the
///   app copy that installed it, recorded as root when the user typed the admin password.
public enum ClientTrust {
    /// The cdhash form used in code signing requirements: 40 lowercase hex characters (20 bytes).
    public static func isCDHash(_ s: String) -> Bool {
        s.count == 40 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    public static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// A code signing requirement string for `NSXPCConnection.setCodeSigningRequirement`.
    /// Every value is validated here; nothing unchecked reaches the requirement compiler.
    /// With no valid team and no valid hash it returns `never` (fail closed).
    public static func requirement(teamID: String?, ownCDHash: String?, pinnedCDHashes: [String]) -> String {
        if let team = teamID, isTeamID(team) {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and "
                + "(identifier \"\(VG.appBundleID)\" or identifier \"\(VG.helperLabel)\")"
        }
        let hashes = ([ownCDHash].compactMap { $0 } + pinnedCDHashes)
            .map { $0.lowercased() }
            .filter(isCDHash)
            .uniqued()
        guard !hashes.isEmpty else { return "never" }
        return hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ")
    }
}

/// The app copy that installed the helper. Stored root-owned at `VG.clientPinsPath`.
public struct ClientPins: Codable, Equatable, Sendable {
    public var appPath: String
    public var cdhashes: [String]
    public var pinnedAt: Date

    public init(appPath: String, cdhashes: [String], pinnedAt: Date = Date()) {
        self.appPath = appPath
        self.cdhashes = cdhashes
        self.pinnedAt = pinnedAt
    }

    /// Only well-formed hashes survive decoding into use.
    public var validHashes: [String] { cdhashes.map { $0.lowercased() }.filter(ClientTrust.isCDHash).uniqued() }
}

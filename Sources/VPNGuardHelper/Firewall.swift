import Foundation
import VPNGuardCore

/// Thin wrapper around pfctl. Our rules live only in the anchor VG.pfAnchor;
/// /etc/pf.conf and Apple's anchors are never changed.
final class Firewall {
    private let pfctl = "/sbin/pfctl"

    /// Takes an enable reference (`pfctl -E`), so other apps that use pf keep working.
    func enable() {
        if let old = try? String(contentsOfFile: VG.pfTokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !old.isEmpty, old.allSatisfy(\.isNumber) {
            Shell.run(pfctl, ["-X", old]) // release the reference from our last run
        }
        let r = Shell.run(pfctl, ["-E"])
        let token = r.output
            .split(separator: "\n")
            .first { $0.contains("Token") }?
            .split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces)
        if let token, !token.isEmpty {
            try? token.write(toFile: VG.pfTokenPath, atomically: true, encoding: .utf8)
        } else if !r.ok {
            Log.error("pfctl -E failed: \(r.output)")
        }
    }

    func isEnabled() -> Bool {
        Shell.run(pfctl, ["-s", "info"]).output.contains("Status: Enabled")
    }

    /// The stock pf.conf defines `anchor "com.apple/*"`. Without it our anchor is never evaluated.
    func hasAnchorPoint() -> Bool {
        Shell.run(pfctl, ["-s", "rules"]).output.contains("anchor \"com.apple/*\"")
    }

    func reloadMainRuleset() {
        let r = Shell.run(pfctl, ["-f", "/etc/pf.conf"])
        if !r.ok { Log.error("Reloading /etc/pf.conf failed: \(r.output)") }
    }

    /// Returns an error message, or nil on success.
    func load(_ rules: String) -> String? {
        let r = Shell.run(pfctl, ["-a", VG.pfAnchor, "-f", "-"], input: rules)
        return r.ok ? nil : "pfctl could not load the rules: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func clear() -> String? {
        let r = Shell.run(pfctl, ["-a", VG.pfAnchor, "-F", "rules"])
        // On a fresh install the anchor may not exist yet; that is the same as "cleared".
        if r.ok || loadedRuleCount() == 0 { return nil }
        return "pfctl could not clear the rules: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func loadedRuleCount() -> Int {
        Shell.run(pfctl, ["-a", VG.pfAnchor, "-s", "rules"]).output
            .split(separator: "\n")
            .filter { $0.hasPrefix("pass") || $0.hasPrefix("block") }
            .count
    }

    /// Drops open connections, so nothing made before the lock keeps running outside the VPN.
    /// `interfaces`: only the states on these cards (nil = all). Falls back to all if pfctl refuses.
    func flushStates(interfaces: [String]? = nil) {
        guard let interfaces, !interfaces.isEmpty else {
            Shell.run(pfctl, ["-F", "states"])
            return
        }
        for name in interfaces where Net.isValidInterfaceName(name) {
            if !Shell.run(pfctl, ["-i", name, "-F", "states"]).ok {
                Shell.run(pfctl, ["-F", "states"])
                return
            }
        }
    }
}

import Foundation

/// Names and paths shared by the app, the helper and the install scripts.
/// Keep these in sync with Resources/helper/*.sh and the launchd plist.
public enum VG {
    public static let version = "1.2.2"

    public static let appBundleID = "local.vpnguard.app"
    public static let helperLabel = "local.vpnguard.helper"
    public static let machService = "local.vpnguard.helper.xpc"
    /// Darwin notification posted by the helper when its status changes.
    public static let statusNotification = "local.vpnguard.status"

    public static let helperPath = "/Library/PrivilegedHelperTools/local.vpnguard.helper"
    public static let launchdPlistPath = "/Library/LaunchDaemons/local.vpnguard.helper.plist"
    public static let configDirectory = "/Library/Application Support/VPNGuard"
    public static let configPath = configDirectory + "/config.json"
    public static let pfTokenPath = "/var/run/vpnguard.pftoken"
    /// Source port of the helper's own DNS lookups of VPN server names. While locked, DNS may leave
    /// from this port only during the helper's lookup (about a second), so it can find a server whose
    /// IP changed while every app's DNS stays blocked.
    public static let dnsLookupPort: UInt16 = 53530
    /// Code hashes of the app copy that installed the helper (written as root at install time).
    /// Used only by builds without a team ID (ad-hoc signed, e.g. the downloadable DMG).
    public static let clientPinsPath = configDirectory + "/clients.json"

    /// Child of the stock `anchor "com.apple/*"` in /etc/pf.conf, so we never edit pf.conf.
    /// "000." sorts before Apple's own sub-anchors (200.AirDrop, 250.ApplicationFirewall),
    /// so our `quick` rules are evaluated first.
    public static let pfAnchor = "com.apple/000.vpnguard"

    public static let logSubsystem = "local.vpnguard"
}

import Foundation

/// Names and paths shared by the app, the helper and the install scripts.
/// Keep these in sync with Resources/helper/*.sh and the launchd plist.
public enum VG {
    public static let version = "1.1.0"

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

    /// Child of the stock `anchor "com.apple/*"` in /etc/pf.conf, so we never edit pf.conf.
    /// "000." sorts before Apple's own sub-anchors (200.AirDrop, 250.ApplicationFirewall),
    /// so our `quick` rules are evaluated first.
    public static let pfAnchor = "com.apple/000.vpnguard"

    public static let logSubsystem = "local.vpnguard"
}

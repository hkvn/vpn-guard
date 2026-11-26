import Foundation
import SystemConfiguration

enum VPNEngine: Equatable {
    /// A VPN in System Settings, run by macOS.
    case macOS
    /// A WireGuard VPN run by the VPN Guard helper.
    case wireGuard
}

/// A VPN VPN Guard can use: one from System Settings -> VPN, or a built-in WireGuard tunnel.
struct VPNService: Identifiable, Hashable {
    let id: String          // SCNetworkService ID, or "wg:<uuid>"
    let name: String
    let kind: String        // L2TP, PPTP, IPSec, IKEv2, VPN (Network Extension), WireGuard
    let remoteAddress: String?
    /// "Send all traffic over VPN connection". nil when we cannot tell.
    let sendsAllTraffic: Bool?
    var engine: VPNEngine = .macOS
    var account: String? = nil
    var tunnelID: UUID? = nil
    /// WireGuard: the address ranges it carries when it does not carry everything.
    var carries: [String]? = nil
    /// macOS "VPN" services: who provides it, e.g. io.tailscale.ipn.macsys (another app) or com.apple.… .
    var subType: String? = nil

    /// Only some addresses go through it (WireGuard AllowedIPs without 0.0.0.0/0). Outside trusted
    /// networks everything else is blocked while it is the VPN.
    var isPartial: Bool { engine == .wireGuard && sendsAllTraffic == false }

    /// Third-party VPN apps (Tailscale and others) show up as "VPN" with their own provider.
    var isOtherApp: Bool {
        guard engine == .macOS, kind == "VPN" else { return false }
        if let subType { return !subType.hasPrefix("com.apple.") }
        return remoteAddress == nil
    }

    /// VPN Guard can rename it: its own WireGuard VPNs, and the macOS VPNs kept in the network
    /// settings (L2TP, PPTP, Cisco IPSec). Not IKEv2 or other apps' VPNs.
    var canRename: Bool { engine == .wireGuard || ["L2TP", "PPTP", "IPSec"].contains(kind) }

    var typeLabel: String {
        if engine == .wireGuard { return "WireGuard" }
        if isOtherApp { return "Other app" }
        return kind == "VPN" ? "IKEv2" : kind
    }

    /// A macOS VPN with "Send all traffic" off: websites stay blocked even when it is up.
    var needsSendAllFix: Bool { engine == .macOS && !isOtherApp && sendsAllTraffic == false }

    var symbol: String {
        switch engine {
        case .wireGuard: return IconTile.tunnelSymbol
        case .macOS: return isOtherApp ? "display" : (typeLabel == "IKEv2" ? "lock" : "globe")
        }
    }

    var summary: String {
        switch engine {
        case .wireGuard: return "WireGuard · built in · \(remoteAddress ?? "")"
        case .macOS: return "\(kind) · macOS VPN\(remoteAddress.map { " · \($0)" } ?? "")"
        }
    }
}

enum VPNCatalog {
    static func services() -> [VPNService] {
        guard let prefs = SCPreferencesCreate(nil, "VPNGuard" as CFString, nil),
              let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]
        else { return [] }

        var out: [VPNService] = []
        for service in all {
            guard SCNetworkServiceGetEnabled(service),
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  let iface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            else { continue }
            let config = SCNetworkInterfaceGetConfiguration(iface) as? [String: Any]
            var kind = type
            var subType: String?
            var remote: String?
            var account: String?

            let pppType = kSCNetworkInterfaceTypePPP as String
            let ipsecType = kSCNetworkInterfaceTypeIPSec as String
            switch type {
            case pppType:
                // Only VPN flavours of PPP (not PPPoE or modems).
                guard let inner = SCNetworkInterfaceGetInterface(iface),
                      let innerType = SCNetworkInterfaceGetInterfaceType(inner) as String?,
                      innerType == kSCNetworkInterfaceTypeL2TP as String || innerType == "PPTP"
                else { continue }
                kind = innerType
                remote = config?[kSCPropNetPPPCommRemoteAddress as String] as? String
                account = config?[kSCPropNetPPPAuthName as String] as? String
            case ipsecType:
                kind = "IPSec"
                remote = config?[kSCPropNetIPSecRemoteAddress as String] as? String
            case "VPN":
                kind = "VPN"
                remote = config?["RemoteAddress"] as? String
                let path = "/\(kSCPrefNetworkServices as String)/\(id)/\(kSCEntNetInterface as String)"
                subType = (SCPreferencesPathGetValue(prefs, path as CFString) as? [String: Any])?["SubType"] as? String
            default:
                continue
            }

            // "Send all traffic" is only a setting for the VPNs macOS runs itself (L2TP, PPTP, IPSec).
            var allTraffic: Bool?
            if kind != "VPN" {
                let pc = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4)
                    .flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] }
                allTraffic = ((pc?[kSCPropNetOverridePrimary as String] as? NSNumber)?.intValue ?? 0) != 0
            }

            out.append(VPNService(id: id, name: (SCNetworkServiceGetName(service) as String?) ?? id,
                                  kind: kind, remoteAddress: remote, sendsAllTraffic: allTraffic, account: account,
                                  subType: subType))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func looksLikeIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }
}

enum VPNState: Equatable {
    case none, invalid, disconnected, connecting, connected, disconnecting

    init(_ s: SCNetworkConnectionStatus) {
        switch s {
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .disconnecting: self = .disconnecting
        default: self = .invalid
        }
    }

    var text: String {
        switch self {
        case .none: return "Not chosen"
        case .invalid: return "Not found"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        }
    }

    var isUp: Bool { self == .connected || self == .connecting }
}

/// Watches and controls one built-in VPN connection (same API as `scutil --nc`).
/// Runs in the user's session, so the password saved in System Settings is used.
@MainActor
final class VPNConnection {
    var onChange: ((VPNState) -> Void)?
    private var connection: SCNetworkConnection?
    private(set) var state: VPNState = .none

    func watch(serviceID: String?) {
        if let c = connection { SCNetworkConnectionSetDispatchQueue(c, nil) }
        connection = nil
        guard let serviceID else {
            update(.none)
            return
        }
        var ctx = SCNetworkConnectionContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                             retain: nil, release: nil, copyDescription: nil)
        let callback: SCNetworkConnectionCallBack = { _, status, info in
            guard let info else { return }
            let me = Unmanaged<VPNConnection>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { me.update(VPNState(status)) }
        }
        guard let c = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, callback, &ctx) else {
            update(.invalid)
            return
        }
        SCNetworkConnectionSetDispatchQueue(c, .main)
        connection = c
        update(VPNState(SCNetworkConnectionGetStatus(c)))
    }

    private func update(_ s: VPNState) {
        state = s
        onChange?(s)
    }

    /// Stops a macOS VPN by its service ID if macOS says it is connecting or connected, whatever
    /// any watcher believes. Used when the user switches to another VPN.
    static func stopService(_ serviceID: String) {
        guard let c = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil) else { return }
        switch SCNetworkConnectionGetStatus(c) {
        case .connecting, .connected: SCNetworkConnectionStop(c, true)
        default: break
        }
    }

    /// pppd's exit code for the last connection (L2TP, PPTP), when macOS has one.
    var lastCause: Int? {
        guard let c = connection, let status = SCNetworkConnectionCopyExtendedStatus(c) as? [String: Any],
              let ppp = status["PPP"] as? [String: Any] else { return nil }
        return (ppp["LastCause"] as? NSNumber)?.intValue
    }

    /// `linger: true` keeps the VPN up if this app quits.
    @discardableResult
    func start() -> Bool {
        guard let c = connection else { return false }
        return SCNetworkConnectionStart(c, nil, true)
    }

    @discardableResult
    func stop() -> Bool {
        guard let c = connection else { return false }
        return SCNetworkConnectionStop(c, true)
    }
}

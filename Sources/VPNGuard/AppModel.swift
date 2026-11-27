import AppKit
import Foundation
import notify
import ServiceManagement
import SystemConfiguration
import SwiftUI
import VPNGuardCore

/// What the UI shows for the current state: one glyph, one color, a title and a line of text.
struct StateLook: Equatable {
    var glyph: GlyphKind
    var tone: Tone
    var title: String
    var subtitle: String
    var primary: PrimaryAction?
    var pulsing = false
}

enum PrimaryAction: Equatable {
    case connectVPN, connecting, chooseVPN, resume, turnOn, installHelper, reinstallHelper, updateHelper
    /// Switch to a VPN that carries all traffic (from the "office network only" state).
    case switchVPN(id: String, name: String)
    /// After a failed connection: start over with the chosen VPN.
    case tryAgain

    var title: String {
        switch self {
        case .switchVPN(_, let name): return "Use \(name) instead"
        case .tryAgain: return "Try Again"
        case .connectVPN: return "Connect VPN"
        case .connecting: return "Connecting…"
        case .chooseVPN: return "Choose a VPN…"
        case .resume: return "Resume Protection"
        case .turnOn: return "Turn On Protection"
        case .installHelper: return "Install Helper…"
        case .reinstallHelper: return "Reinstall Helper…"
        case .updateHelper: return "Update Helper…"
        }
    }
}

/// Why a VPN did not connect, and when.
struct VPNProblem: Equatable {
    let failure: VPNFailure
    let at: Date
}

/// One network card in the popover.
struct NetworkCardInfo: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let trusted: Bool?
    var pill: String = ""
    /// The network macOS sends traffic through, when there are several (shown first, highlighted).
    var inUse = false
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, networks, vpn, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .networks: return "Networks"
        case .vpn: return "VPN"
        case .about: return "Helper & About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .networks: return "wifi"
        case .vpn: return "globe"
        case .about: return "shield"
        }
    }

    var color: Color {
        switch self {
        case .general: return Color(hex: 0x8E8E93)
        case .networks: return Color(hex: 0x0A84FF)
        case .vpn: return Color(hex: 0x248A3D)
        case .about: return Color(hex: 0x48484A)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum HelperState: Equatable {
        case checking
        case notInstalled
        case notResponding(String)
        case ready
        case outdated(String)
    }

    @Published private(set) var helperState: HelperState = .checking
    @Published private(set) var status: GuardStatus?
    /// VPNs from System Settings (the WireGuard ones come from the helper's status).
    @Published private(set) var macVPNServices: [VPNService] = []
    @Published private(set) var macVPNState: VPNState = .none
    @Published private(set) var macConnectedSince: Date?
    @Published private(set) var busy = false
    @Published var settingsPane: SettingsPane = .general
    /// Name of a VPN the user just created as a profile; cleared when it shows up.
    @Published private(set) var pendingVPNName: String?

    /// The VPN the user chose for untrusted networks (the ✓ in Settings).
    @Published var selectedVPNID: String? {
        didSet {
            guard selectedVPNID != oldValue, !isPreview else { return }
            UserDefaults.standard.set(selectedVPNID, forKey: Keys.vpnServiceID)
            // One VPN at a time: take the one in use down first, then watch the new choice.
            let inUse = backupVPNID ?? oldValue
            switchingVPN = true
            backupVPNID = nil
            stopVPN(id: inUse, replacedBy: nil)
            forgetFailures()
            vpn.watch(serviceID: Self.isWireGuardID(selectedVPNID) ? nil : selectedVPNID)
            switchingVPN = false
            syncVPNServers()
        }
    }
    /// A backup VPN used on this network because the chosen one did not connect. Not saved.
    @Published private(set) var backupVPNID: String?
    /// The VPN being measured by Compare VPNs (Network Quality). Wins over the backup and the chosen
    /// VPN while it runs; the automatic VPN, backups and notices wait meanwhile.
    @Published private(set) var comparingVPNID: String?
    /// Ping, speed and VPN stability (the Network Quality window).
    let quality: QualityMonitor
    /// When VPN Guard or the user last asked a VPN to stop: a "down" soon after is not a drop.
    private var lastStopRequest = Date.distantPast
    private var qualityNeeded = false
    private var qualityUp = false
    /// The VPN that came up last (for the "dropped" event: by then the active one may have changed).
    private var qualityUpName: String?
    private var connectingSince: Date?
    /// Why a VPN did not connect, by VPN id. Forgotten when it connects or the network changes.
    @Published private(set) var vpnProblems: [String: VPNProblem] = [:]
    /// Settings → VPN: try the other VPNs when the chosen one fails. Off by default: a backup sends
    /// your traffic out somewhere else than the VPN you chose.
    @Published var useBackupVPN: Bool {
        didSet {
            guard useBackupVPN != oldValue, !isPreview else { return }
            UserDefaults.standard.set(useBackupVPN, forKey: Keys.useBackupVPN)
            if !useBackupVPN, backupVPNID != nil { switchActive(to: nil) }
            runAutoVPN()
        }
    }
    /// Settings → General: macOS notifications when the internet is blocked.
    @Published var notifyWhenBlocked: Bool {
        didSet {
            guard notifyWhenBlocked != oldValue, !isPreview else { return }
            UserDefaults.standard.set(notifyWhenBlocked, forKey: Keys.notifyWhenBlocked)
            if notifyWhenBlocked { askForNotifications() }
        }
    }
    /// What macOS says about VPN Guard's notifications: allowed, refused, or its question was not answered.
    @Published private(set) var notificationAccess: Notifier.Access = .allowed
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect); runAutoVPN() }
    }
    /// Settings → General: how the menu bar shield looks. Monochrome by default, like other Mac icons.
    @Published var menuBarIconStyle: MenuBarIconStyle = .monochrome {
        didSet { UserDefaults.standard.set(menuBarIconStyle.rawValue, forKey: Keys.menuBarIconStyle) }
    }
    @Published var autoDisconnect: Bool {
        didSet { UserDefaults.standard.set(autoDisconnect, forKey: Keys.autoDisconnect) }
    }

    private enum Keys {
        static let vpnServiceID = "vpnServiceID"
        static let autoConnect = "autoConnect"
        static let autoDisconnect = "autoDisconnect"
        /// The server address this app added for the selected VPN (so it can swap it later).
        static let autoServer = "autoServer"   // before 1.1.2: one server
        static let autoServers = "autoServers"
        static let vpnStartedByUs = "vpnStartedByVPNGuard"
        static let menuBarIconStyle = "menuBarIconStyle"
        static let onboardingDone = "onboardingDone"
        static let pauseLength = "pauseLength"
        static let useBackupVPN = "useBackupVPN"
        static let notifyWhenBlocked = "notifyWhenBlocked"
    }

    private let client = HelperClient()
    private let vpn = VPNConnection()
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var timer: Timer?
    private(set) var isPreview = false

    // Auto VPN bookkeeping, reset whenever the network changes.
    private var networkKey = ""
    private var userStoppedVPN = false { willSet { if newValue != userStoppedVPN { objectWillChange.send() } } }
    private var autoDisconnectDoneFor: String?
    private var lastAutoStart = Date.distantPast { willSet { if newValue != lastAutoStart { objectWillChange.send() } } }
    private var autoStartAttempts = 0 { willSet { if newValue != autoStartAttempts { objectWillChange.send() } } }
    /// When the router's hardware address started to be unknown (reason "resolving"), in awake time
    /// (`awake`): the helper locks as "resolving" before sleep, and the hours asleep must not count.
    private var resolvingSince: TimeInterval?
    /// The networks (card, address, router) the macOS VPN connected on.
    private var vpnConnectedOn: Set<String>?
    /// When the last network went away (a Wi-Fi blip or sleep keeps your VPN choice, see AutoVPN).
    private var networkGoneSince: Date?

    // Failed connections and backup VPNs, reset when the network changes.
    /// Failed tries in a row with the VPN in use.
    private var failedTries = 0
    /// VPNs that already failed on this network (so backups are not tried in circles).
    private var failedHere: Set<String> = []
    /// A macOS VPN attempt is running (connecting seen, no result yet), and when it started.
    private var attemptOpen = false
    private var attemptStarted = Date.distantPast
    private var wgConnectingSince: Date?
    /// True while this code moves the watcher to another VPN: its state changes are not failures.
    private var switchingVPN = false
    /// VPN Guard (or the user through it) asked macOS to stop the VPN: the next "disconnected" is not a failure.
    private var stoppingVPN = false
    /// A failure reason is being read from the macOS log.
    private var readingFailure = false
    private var retryTimerSet = false
    // Notifications.
    private let notifier = Notifier()
    /// In awake time, like `resolvingSince`: a night asleep is not "blocked for hours".
    private var blockedSince: TimeInterval?
    private var lastNotice: VPNNotice?
    static let retryDelays: [TimeInterval] = [0, 5, 15, 30, 60]

    private var pendingTimer: Timer?
    private var pendingStarted = Date.distantPast

    // Keeping the selected VPN's server in the helper's allow list.
    private var serverSyncInFlight = false
    private var serverSyncFailedFor: String?

    static var helperInstalledOnDisk: Bool { FileManager.default.fileExists(atPath: VG.helperPath) }
    static var needsOnboarding: Bool {
        !helperInstalledOnDisk || !UserDefaults.standard.bool(forKey: Keys.onboardingDone)
    }

    init() {
        quality = QualityMonitor(preview: false)
        let d = UserDefaults.standard
        d.register(defaults: [Keys.autoConnect: true, Keys.autoDisconnect: true, Keys.notifyWhenBlocked: true])
        selectedVPNID = d.string(forKey: Keys.vpnServiceID)
        autoConnect = d.bool(forKey: Keys.autoConnect)
        autoDisconnect = d.bool(forKey: Keys.autoDisconnect)
        useBackupVPN = d.bool(forKey: Keys.useBackupVPN)
        notifyWhenBlocked = d.bool(forKey: Keys.notifyWhenBlocked)
        menuBarIconStyle = MenuBarIconStyle(rawValue: d.string(forKey: Keys.menuBarIconStyle) ?? "") ?? .monochrome

        // Profiles hold a password: never leave old ones lying around.
        try? FileManager.default.removeItem(at: Self.profileFolder)

        reloadVPNServices()
        watchNetworkSettings()
        quality.model = self
        vpn.onChange = { [weak self] state in
            guard let self else { return }
            if state == .connected, self.macVPNState != .connected { self.macConnectedSince = Date() }
            if state != .connected { self.macConnectedSince = nil }
            self.macVPNState = state
            if !self.switchingVPN { self.noteMacVPN(state) }
            self.runAutoVPN()
        }
        vpn.watch(serviceID: Self.isWireGuardID(selectedVPNID) ? nil : selectedVPNID)

        // The helper posts this whenever its state changes, so the icon updates at once.
        notify_register_dispatch(VG.statusNotification, &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.runAutoVPN()
            }
        }
        // macOS may move it by up to 2 s to wake the Mac together with other timers (saves power).
        timer?.tolerance = 2
        refresh()
        if notifyWhenBlocked { askForNotifications() }
    }

    // MARK: - Derived state for the UI

    var helperReady: Bool {
        switch helperState {
        case .ready, .outdated: return status != nil
        default: return false
        }
    }

    var helperNeedsUpdate: Bool {
        if case .outdated = helperState { return true }
        return false
    }

    var protectionOn: Bool { status?.config.enabled ?? false }
    var isPaused: Bool { status?.reason == .paused }
    var pausedUntil: Date? { isPaused ? status?.config.pausedUntil : nil }
    /// Length of the current pause, for the progress bar.
    var pauseLength: TimeInterval {
        max(60, UserDefaults.standard.double(forKey: Keys.pauseLength))
    }

    static func isWireGuardID(_ id: String?) -> Bool { id?.hasPrefix("wg:") ?? false }

    var wireGuardServices: [VPNService] {
        (status?.config.wireguard ?? []).map { t in
            VPNService(id: "wg:\(t.id.uuidString)", name: t.name, kind: "WireGuard", remoteAddress: t.endpoint,
                       sendsAllTraffic: t.isFullTunnel, engine: .wireGuard, tunnelID: t.id,
                       carries: t.isFullTunnel ? nil : t.allowedIPs)
        }
    }

    var vpnServices: [VPNService] { wireGuardServices + macVPNServices }
    var selectedVPN: VPNService? { vpnServices.first { $0.id == selectedVPNID } }
    /// The VPN in use: the chosen one, or the backup that replaces it on this network.
    var activeVPNID: String? { comparingVPNID ?? backupVPNID ?? selectedVPNID }
    var activeVPN: VPNService? { vpnServices.first { $0.id == activeVPNID } }
    /// The chosen VPN while a backup is used instead of it.
    var replacedVPN: VPNService? { backupVPNID == nil ? nil : selectedVPN }
    /// Other VPNs that may stand in for the chosen one: they must carry all traffic.
    var backupCandidates: [VPNService] {
        vpnServices.filter { $0.id != selectedVPNID && !$0.isPartial && !$0.isOtherApp && !$0.needsSendAllFix }
    }
    func problem(for v: VPNService?) -> VPNProblem? { v.flatMap { vpnProblems[$0.id] } }

    func tunnel(for service: VPNService?) -> WireGuardTunnel? {
        guard let id = service?.tunnelID else { return nil }
        return status?.config.wireguard.first { $0.id == id }
    }

    /// The helper's tunnel, if it is the selected VPN.
    var wgRuntime: WireGuardRuntime? {
        guard let id = activeVPN?.tunnelID, let rt = status?.wg, rt.tunnelID == id else { return nil }
        return rt
    }

    var vpnState: VPNState {
        guard let v = activeVPN else {
            if activeVPNID == QualityMonitor.noVPNID { return .disconnected }   // a test without VPN
            return activeVPNID == nil ? .none : .invalid
        }
        guard v.engine == .wireGuard else { return macVPNState }
        guard status?.config.wgActive == v.tunnelID else { return .disconnected }
        return wgRuntime?.isConnected() == true ? .connected : .connecting
    }

    var vpnConnectedSince: Date? {
        guard activeVPN?.engine == .wireGuard else { return macConnectedSince }
        return vpnState == .connected ? wgRuntime?.startedAt : nil
    }
    var untrustedLinks: [NetworkLink] { status?.links.filter { $0.trustedName == nil } ?? [] }

    var canTrustCurrent: Bool {
        let links = untrustedLinks
        return helperReady && !links.isEmpty && links.allSatisfy { $0.routerMAC != nil }
    }

    func isCurrent(_ t: TrustedNetwork) -> Bool {
        status?.links.contains { $0.routerMAC == t.routerMAC } ?? false
    }

    /// The network macOS sends traffic through (matters when the Mac is on several).
    var primaryLink: NetworkLink? {
        guard let s = status else { return nil }
        return s.links.first { $0.interface == s.primaryInterface } ?? s.links.first
    }

    /// Several networks, and macOS uses a trusted one: normal internet, the others are VPN only.
    var mixedUsesTrusted: Bool { status?.reason == .mixed && primaryLink?.trustedName != nil }

    /// "Your iPhone hotspot" at the start of a sentence, the card name otherwise.
    static func subjectName(_ link: NetworkLink) -> String {
        if link.routerIP == "172.20.10.1" { return "Your iPhone hotspot" }
        return TrustPick.isPhoneHotspot(link) ? "Your phone hotspot" : link.label
    }

    static func objectName(_ link: NetworkLink) -> String {
        if link.routerIP == "172.20.10.1" { return "your iPhone" }
        return TrustPick.isPhoneHotspot(link) ? "your phone" : link.label
    }

    static func kindName(_ link: NetworkLink) -> String {
        if link.routerIP == "172.20.10.1" { return "iPhone hotspot" }
        return TrustPick.isPhoneHotspot(link) ? "Phone hotspot" : link.label
    }

    /// The label on a network card: trusted, only for the VPN (another network is trusted), or not trusted.
    func pillText(for link: NetworkLink) -> String {
        if link.trustedName != nil { return "Trusted" }
        return status?.reason == .mixed ? "VPN only" : "Not trusted"
    }

    var trustedNamesHere: String {
        (status?.links.compactMap(\.trustedName) ?? []).uniqued().joined(separator: " and ")
    }

    var look: StateLook {
        switch helperState {
        case .checking:
            return StateLook(glyph: .dots, tone: .gray, title: "Checking…", subtitle: "Talking to the VPN Guard helper.", pulsing: true)
        case .notInstalled:
            return StateLook(glyph: .bang, tone: .red, title: "Set up VPN Guard",
                             subtitle: "Install the small helper that runs the macOS firewall for you.", primary: .installHelper)
        case .notResponding:
            return StateLook(glyph: .bang, tone: .red, title: "Needs attention",
                             subtitle: "The helper is not answering. Reinstall it to fix this.", primary: .reinstallHelper)
        case .ready, .outdated:
            break
        }
        guard let s = status else {
            return StateLook(glyph: .dots, tone: .gray, title: "Checking…", subtitle: "Talking to the VPN Guard helper.", pulsing: true)
        }
        if s.config.enabled, s.firewallError != nil {
            return StateLook(glyph: .bang, tone: .red, title: "Firewall problem",
                             subtitle: "The firewall rules could not be set. Reinstall the helper.", primary: .reinstallHelper)
        }
        let vpnName = activeVPN?.name ?? "your VPN"
        switch s.reason {
        case .disabled:
            return StateLook(glyph: .dashed, tone: .gray, title: "Protection is off",
                             subtitle: "Turn it on to block the internet outside your trusted networks.", primary: .turnOn)
        case .paused:
            return StateLook(glyph: .pause, tone: .yellow, title: "Paused",
                             subtitle: "Normal internet for a few minutes, so you can sign in to the Wi‑Fi.", primary: .resume)
        case .trusted:
            return StateLook(glyph: .check, tone: .blue, title: "Trusted network",
                             subtitle: "You are at \(trustedNamesHere). Normal internet, no VPN needed.")
        case .noNetwork:
            return StateLook(glyph: .empty, tone: .gray, title: "No network",
                             subtitle: "Join a network. VPN Guard checks it right away.")
        case .resolving:
            return StateLook(glyph: .dots, tone: .gray, title: "Checking the network…",
                             subtitle: "Reading the router's address.", pulsing: true)
        case .mixed:
            if let used = primaryLink, let name = used.trustedName {
                let others = untrustedLinks.map(Self.subjectName)
                let one = others.count == 1
                return StateLook(glyph: .check, tone: .blue, title: "Trusted network",
                                 subtitle: "Your Mac uses \(name). \(others.joined(separator: " and ")) \(one ? "is" : "are") not trusted, so only the VPN may use \(one ? "it" : "them").")
            }
            let through = primaryLink.map(Self.objectName) ?? "a network"
            return untrustedLook(vpnName: vpnName,
                                 protected: "Your Mac sends traffic through \(through), which is not trusted, so all of it goes through your VPN.")
        case .untrusted:
            return untrustedLook(vpnName: vpnName, protected: "This network is not trusted, so all traffic goes through your VPN.")
        }
    }

    private func untrustedLook(vpnName: String, protected: String) -> StateLook {
        if activeVPN == nil {
            return StateLook(glyph: .cross, tone: .orange, title: "Blocked",
                             subtitle: "Choose the VPN to use on networks you don't trust.", primary: .chooseVPN)
        }
        switch vpnState {
        case .connected:
            if let v = activeVPN, v.isPartial {
                // Connected, but it only carries some addresses: everything else is blocked here.
                let who = partialNetworkName(v).map { "\($0) addresses" } ?? "some addresses"
                return StateLook(glyph: .lock, tone: .orange, title: partialLabel(v),
                                 subtitle: "\(v.name) only carries \(who). Other websites are blocked on this network.",
                                 primary: fullVPNAlternative.map { .switchVPN(id: $0.id, name: $0.name) })
            }
            if let main = replacedVPN {
                return StateLook(glyph: .lock, tone: .green, title: "Protected",
                                 subtitle: "\(main.name) could not connect, so your backup \(vpnName) is used. All traffic goes through it.")
            }
            return StateLook(glyph: .lock, tone: .green, title: "Protected", subtitle: protected)
        case .connecting:
            if let main = replacedVPN {
                return StateLook(glyph: .dots, tone: .orange, title: "Connecting…",
                                 subtitle: "\(main.name) could not connect. Starting your backup \(vpnName).",
                                 primary: .connecting, pulsing: true)
            }
            return StateLook(glyph: .dots, tone: .orange, title: "Connecting…",
                             subtitle: "Starting \(vpnName). The internet opens as soon as it is up.",
                             primary: .connecting, pulsing: true)
        default:
            if let p = problem(for: activeVPN) {
                // Say why, in plain words (design: canvas "Popover · blocked, with the reason").
                return StateLook(glyph: .cross, tone: .orange, title: "Blocked",
                                 subtitle: p.failure.sentence(vpn: vpnName), primary: .tryAgain)
            }
            return StateLook(glyph: .cross, tone: .orange, title: "Blocked",
                             subtitle: "The VPN is off, so nothing on this Mac can reach the internet here.", primary: .connectVPN)
        }
    }

    // MARK: VPNs that only carry some addresses

    func partialNetworkName(_ v: VPNService) -> String? {
        status?.config.trustedNetworkName(carriedBy: v.carries ?? [])
    }

    /// "Office network only" when it carries a trusted network, else "Some addresses only".
    func partialLabel(_ v: VPNService) -> String {
        partialNetworkName(v).map { "\($0) network only" } ?? "Some addresses only"
    }

    /// Rename a VPN: WireGuard in VPN Guard, L2TP / PPTP / Cisco IPSec in macOS too.
    func renameVPN(_ v: VPNService) {
        guard v.canRename else { return }
        let note = v.engine == .wireGuard ? "" : " The new name is also used in System Settings → VPN."
        guard let raw = Dialogs.askName(title: "Rename VPN", message: "\(v.name) · \(v.typeLabel).\(note)",
                                        button: "Rename", initial: v.name, placeholder: "Office VPN"),
              let name = DisplayName.clean(raw), name != v.name else { return }
        if v.engine == .wireGuard, let id = v.tunnelID {
            perform(.wgRename(id: id, name: name))
        } else {
            perform(.renameMacVPN(serviceID: v.id, name: name)) { [weak self] in self?.reloadVPNServices() }
        }
    }

    /// A VPN that carries all traffic, to offer instead of a partial one.
    var fullVPNAlternative: VPNService? {
        vpnServices.first { $0.id != selectedVPNID && !$0.isPartial && !$0.isOtherApp && !$0.needsSendAllFix }
    }

    /// Choose the VPN used on untrusted networks. A partial one needs a yes first (Cancel is the default).
    func choose(_ v: VPNService) {
        guard v.id != selectedVPNID else { return }
        if v.isPartial {
            let who = partialNetworkName(v).map { "\($0) addresses" } ?? "some addresses"
            let ranges = (v.carries ?? []).joined(separator: ", ")
            let answer = Dialogs.choose(
                title: "Use “\(v.name)” on networks you don’t trust?",
                message: "\(v.name) only carries \(who) (\(ranges)). While it is your VPN on an untrusted network, other websites will be blocked.\n\nFor full protection, choose a VPN that carries all traffic, or ask for a WireGuard file with AllowedIPs = 0.0.0.0/0.",
                buttons: ["Cancel", "Use \(v.name)"], warning: true)
            guard answer == 1 else { return }
        }
        selectedVPNID = v.id
    }

    var networkCards: [NetworkCardInfo] {
        guard let s = status else { return [] }
        if s.links.isEmpty {
            return [NetworkCardInfo(id: "none", symbol: "wifi.slash", title: "No network", detail: "Not connected", trusted: nil)]
        }
        let several = s.links.count > 1
        let cards = s.links.map { link in
            let hotspot = TrustPick.isPhoneHotspot(link)
            let kind = Self.kindName(link)
            let inUse = several && link.interface == s.primaryInterface
            if let name = link.trustedName {
                return NetworkCardInfo(id: link.interface, symbol: Self.symbol(for: link, hotspot: hotspot), title: name,
                                       detail: "\(kind) · \(link.routerIP)", trusted: true, pill: pillText(for: link), inUse: inUse)
            }
            return NetworkCardInfo(id: link.interface, symbol: Self.symbol(for: link, hotspot: hotspot), title: kind,
                                   detail: "Router \(link.routerIP)", trusted: false, pill: pillText(for: link), inUse: inUse)
        }
        // The network in use first (the user's request); the rest keep their order.
        return cards.filter(\.inUse) + cards.filter { !$0.inUse }
    }

    /// The card icon shows how the Mac is connected: Wi‑Fi, phone, or a cable (USB LAN, Ethernet,
    /// Thunderbolt…). The card's title already says which network it is.
    static func symbol(for link: NetworkLink, hotspot: Bool) -> String {
        let label = link.label.lowercased()
        if hotspot || label.contains("iphone") || label.contains("ipad") { return "personalhotspot" }
        if label.contains("wi-fi") || label.contains("wi‑fi") || label.contains("wifi") || label.contains("airport") { return "wifi" }
        return "cable.connector.horizontal"
    }

    static func symbol(forTrustedName name: String) -> String {
        let n = name.lowercased()
        if ["home", "nhà", "house"].contains(where: n.contains) { return "house" }
        if ["office", "văn phòng", "work", "công ty", "vp"].contains(where: n.contains) { return "building.2" }
        return "wifi"
    }

    /// One line under the VPN name. `now` comes from a TimelineView, so the minutes tick.
    func vpnDetail(now: Date) -> String {
        guard let vpn = activeVPN else { return "Choose the VPN to use" }
        let server = vpn.remoteAddress ?? ""
        if vpn.engine == .wireGuard {
            let rt = wgRuntime
            switch vpnState {
            case .connected:
                if vpn.isPartial, let ranges = vpn.carries, !ranges.isEmpty {
                    return "Only \(ranges.joined(separator: ", "))"   // short: fits the 340 pt card
                }
                let since = vpnConnectedSince.map { Self.duration(now.timeIntervalSince($0)) } ?? "just now"
                if let main = replacedVPN {
                    return since == "just now" ? "Backup for \(main.name)" : "Backup for \(main.name) · \(since)"
                }
                let traffic = rt.map { "↓ \(Self.bytes($0.rxBytes)) ↑ \(Self.bytes($0.txBytes))" } ?? ""
                return [since == "just now" ? "Connected just now" : since, traffic].filter { !$0.isEmpty }.joined(separator: " · ")
            case .connecting:
                if let e = rt?.error { return e }
                if rt?.isRunning == true { return "Waiting for \(server) to answer…" }
                return "Connecting to \(server)…"
            default:
                return vpnNotNeeded ?? problemDetail(now: now) ?? "WireGuard · Disconnected"
            }
        }
        switch vpnState {
        case .connected:
            if let main = replacedVPN {
                let d = vpnConnectedSince.map { Self.duration(now.timeIntervalSince($0)) } ?? "just now"
                return d == "just now" ? "Backup for \(main.name)" : "Backup for \(main.name) · \(d)"
            }
            // Several networks and the VPN runs through an untrusted one: say which (short: 340 pt card).
            if status?.reason == .mixed, let via = primaryLink, via.trustedName == nil {
                return "Connected via \(via.label)"
            }
            if let since = vpnConnectedSince {
                let d = Self.duration(now.timeIntervalSince(since))
                return d == "just now" ? "Connected just now" : "Connected for \(d)"
            }
            return "Connected"
        case .connecting: return "Connecting to \(server)…"
        case .disconnecting: return "Disconnecting…"
        case .invalid: return "Not found in System Settings"
        case .none, .disconnected:
            return vpnNotNeeded ?? problemDetail(now: now) ?? "Disconnected"
        }
    }

    /// "Login refused · next try in 30 s" for the VPN card, when the last try failed.
    private func problemDetail(now: Date) -> String? {
        guard let p = problem(for: activeVPN) else { return nil }
        let label = p.failure.label
        guard let next = nextTry, label.count <= 22 else { return label }   // must fit the 340 pt card
        let seconds = Int(next.timeIntervalSince(now).rounded(.up))
        return seconds > 0 ? "\(label) · next try in \(seconds) s" : "\(label) · trying again…"
    }

    /// When VPN Guard will start the VPN again by itself, if it will.
    var nextTry: Date? {
        guard autoConnect, !userStoppedVPN, vpnState == .disconnected, lastAutoStart != .distantPast,
              status?.mode == .locked else { return nil }
        return lastAutoStart.addingTimeInterval(Self.retryDelays[min(autoStartAttempts, Self.retryDelays.count - 1)])
    }

    /// The VPN card counts down to the next try: it needs a fresh text every second.
    var showsRetryCountdown: Bool { problem(for: activeVPN) != nil && nextTry != nil }

    /// Why the VPN is not needed right now, or nil if it is.
    private var vpnNotNeeded: String? {
        if status?.reason == .trusted { return "Not needed on this network" }
        if mixedUsesTrusted, let name = primaryLink?.trustedName { return "Not needed: \(name) in use" }
        return nil
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    /// Short sizes for one line: 840 KB, 3.1 MB, 24 MB, 1.2 GB.
    static func bytes(_ n: UInt64) -> String {
        let v = Double(n)
        func fmt(_ x: Double, _ unit: String) -> String {
            x >= 10 ? "\(Int(x.rounded())) \(unit)" : String(format: "%.1f \(unit)", x)
        }
        if v < 1_000_000 { return "\(Int((v / 1000).rounded())) KB" }
        if v < 1_000_000_000 { return fmt(v / 1_000_000, "MB") }
        return fmt(v / 1_000_000_000, "GB")
    }

    static func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Talking to the helper

    func refresh() {
        guard !isPreview else { return }
        client.send(.status) { [weak self] result in
            Task { @MainActor in self?.apply(result) }
        }
    }

    private func apply(_ result: Result<GuardStatus, Error>) {
        switch result {
        case .success(let s):
            // Publish only what changed: this runs every 10 s, and each publish redraws every view
            // (the closed popover too), which cost about 200 MB of graphics memory for a moment.
            if status != s { status = s }
            let state: HelperState = s.helperVersion == VG.version ? .ready : .outdated(s.helperVersion)
            if helperState != state { helperState = state }
            syncVPNServers()
            runAutoVPN()
        case .failure(let error):
            if status != nil { status = nil }
            let state: HelperState = Self.helperInstalledOnDisk ? .notResponding(error.localizedDescription) : .notInstalled
            if helperState != state { helperState = state }
        }
    }

    private func perform(_ command: HelperCommand, then: (() -> Void)? = nil) {
        guard !isPreview else { return }
        busy = true
        client.send(command) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let s):
                    self.apply(.success(s))
                    then?()
                case .failure(let error):
                    Dialogs.error("VPN Guard", error.localizedDescription)
                    self.refresh()
                }
            }
        }
    }

    // MARK: - User actions

    func runPrimary(_ action: PrimaryAction, openSettings: (SettingsPane) -> Void) {
        switch action {
        case .connectVPN: connectVPN()
        case .connecting: break
        case .chooseVPN: openSettings(.vpn)
        case .resume: resume()
        case .turnOn: setProtection(true)
        case .installHelper, .reinstallHelper, .updateHelper: installHelper()
        case .switchVPN(let id, _): selectedVPNID = id
        case .tryAgain: retryVPN()
        }
    }

    func trustCurrentNetwork() {
        let links = untrustedLinks
        guard !links.isEmpty else { return }
        if TrustPick.needsPicker(links) {
            let picker = TrustPickerModel(candidates: links, primaryInterface: status?.primaryInterface)
            guard TrustPickerPresenter.run(picker), !picker.ticked.isEmpty else { return }
            perform(.trustRouters(name: picker.cleanName, macs: Array(picker.ticked)))
            return
        }
        let lines = links.map { "\($0.label) · router \($0.routerIP) (\($0.routerMAC ?? "?"))" }.joined(separator: "\n")
        guard let name = Dialogs.askName(
            title: "Trust this network?",
            message: "\(lines)\n\nOn this network the internet works without the VPN. Give it a name, for example Office or Home.",
            button: "Trust"
        ) else { return }
        perform(.trustCurrent(name: name))
    }

    func rename(_ t: TrustedNetwork) {
        guard let name = Dialogs.askName(title: "Rename network", message: "Router \(t.routerMAC)",
                                         button: "Rename", initial: t.name) else { return }
        perform(.rename(id: t.id, name: name))
    }

    func untrust(_ t: TrustedNetwork) {
        if protectionOn && isCurrent(t) && !vpnState.isUp {
            guard Dialogs.confirm(
                title: "Remove \"\(t.name)\"?",
                message: "You are on this network now. The internet will stop here until the VPN connects.",
                button: "Remove"
            ) else { return }
        }
        perform(.untrust(id: t.id))
    }

    func setProtection(_ on: Bool) {
        if on, let s = status {
            var warnings: [String] = []
            if s.config.allowedIPs.isEmpty {
                warnings.append("No VPN server is allowed through the firewall yet, so the VPN cannot connect while blocked. Choose your VPN in Settings first.")
            }
            let blockedNow = !s.links.isEmpty && s.links.contains { $0.trustedName == nil } && vpnState != .connected
            if blockedNow {
                warnings.append("This network is not trusted. The internet stops until the VPN connects\(autoConnect && selectedVPN != nil ? " (VPN Guard starts it now)" : "").")
            }
            if !warnings.isEmpty {
                guard Dialogs.confirm(title: "Turn on protection?", message: warnings.joined(separator: "\n\n"), button: "Turn On")
                else { return }
            }
        }
        perform(.setEnabled(on)) { [weak self] in
            // Turning on at a café: start the VPN now.
            self?.userStoppedVPN = false
            self?.lastAutoStart = .distantPast
            self?.runAutoVPN()
        }
    }

    func pause(minutes: Int) {
        UserDefaults.standard.set(Double(minutes * 60), forKey: Keys.pauseLength)
        perform(.pause(minutes: minutes))
    }

    func extendPause(minutes: Int) {
        let remaining = max(0, (pausedUntil ?? Date()).timeIntervalSinceNow)
        let total = Int((remaining / 60).rounded(.up)) + minutes
        UserDefaults.standard.set(Double(total * 60), forKey: Keys.pauseLength)
        perform(.pause(minutes: min(total, 1440)))
    }

    func resume() { perform(.resume) }

    func setVPNServers(_ servers: [String]) { perform(.setVPNServers(servers)) }

    func addVPNServer(_ value: String) {
        let ip = value.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        setVPNServers((status?.config.vpnServers ?? []) + [ip])
    }

    func removeVPNServer(_ ip: String) {
        setVPNServers((status?.config.vpnServers ?? []).filter { $0 != ip })
    }

    /// Servers the app put in the helper's allow list (the rest were typed by hand).
    private var autoServers: [String] {
        let d = UserDefaults.standard
        if let list = d.stringArray(forKey: Keys.autoServers) { return list }
        return d.string(forKey: Keys.autoServer).map { [$0] } ?? []
    }

    /// Keeps the servers of every macOS VPN (the chosen one first) in the helper's allow list, so any
    /// of them can connect while blocked, also right after switching VPN. Host names are fine: the
    /// helper looks them up and answers them. WireGuard servers are added by the helper itself.
    private func syncVPNServers() {
        guard !isPreview, helperReady, let s = status, !serverSyncInFlight else { return }
        let macVPNs = macVPNServices.filter { $0.engine == .macOS && !$0.isOtherApp }
        let chosen = macVPNs.first { $0.id == selectedVPNID }
        let wanted = ([chosen] + macVPNs.filter { $0.id != selectedVPNID }).compactMap { $0?.remoteAddress }
        let merged = ServerList.merge(current: s.config.vpnServers, previousAuto: autoServers, wanted: wanted)
        guard merged.list != s.config.vpnServers else {
            // Runs every 10 s: write only when it changed.
            if merged.auto != autoServers { UserDefaults.standard.set(merged.auto, forKey: Keys.autoServers) }
            return
        }
        let key = merged.list.joined(separator: ",")
        guard serverSyncFailedFor != key else { return }
        serverSyncInFlight = true
        client.send(.setVPNServers(merged.list)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.serverSyncInFlight = false
                switch result {
                case .success(let st):
                    UserDefaults.standard.set(merged.auto, forKey: Keys.autoServers)
                    self.serverSyncFailedFor = nil
                    self.status = st
                case .failure(let error):
                    self.serverSyncFailedFor = key
                    NSLog("VPN Guard: could not update the VPN servers: \(error.localizedDescription)")
                }
            }
        }
    }

    func reloadVPNServices() {
        guard !isPreview else { return }
        let services = VPNCatalog.services()
        if services != macVPNServices { macVPNServices = services }
        syncVPNServers()
    }

    /// The network settings of macOS, watched so that a VPN added, removed or given another server in
    /// System Settings is allowed through the lock at once (it waited for Settings or an app restart,
    /// and while locked the VPN could not reach its new server).
    private var networkSettings: SCPreferences?
    private var networkSettingsReload: DispatchWorkItem?

    private func watchNetworkSettings() {
        guard !isPreview, let prefs = SCPreferencesCreate(nil, "VPNGuard-watch" as CFString, nil) else { return }
        var ctx = SCPreferencesContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: SCPreferencesCallBack = { prefs, _, info in
            SCPreferencesSynchronize(prefs)
            guard let info else { return }
            let me = Unmanaged<AppModel>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { me.networkSettingsChanged() }
        }
        guard SCPreferencesSetCallback(prefs, callback, &ctx), SCPreferencesSetDispatchQueue(prefs, .main) else {
            NSLog("VPN Guard: could not watch the network settings")
            return
        }
        networkSettings = prefs
    }

    /// System Settings saves in several steps: read once when it is quiet.
    private func networkSettingsChanged() {
        networkSettingsReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadVPNServices() }
        networkSettingsReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// True while the running VPN is one VPN Guard started by itself (kept across app restarts, because
    /// the VPN keeps running when the app quits). Only such a VPN is stopped when protection goes off.
    private var vpnStartedByUs: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.vpnStartedByUs) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.vpnStartedByUs) }
    }

    func connectVPN() {
        guard !isPreview else { return }
        userStoppedVPN = false
        vpnStartedByUs = false
        failedTries = 0
        if activeVPN?.engine == .wireGuard {
            startSelectedVPN()
            return
        }
        if !vpn.start() {
            Dialogs.error("VPN did not start", "macOS refused to start \"\(activeVPN?.name ?? "the VPN")\". Try it once from System Settings → VPN so the password is saved.")
        }
    }

    /// "Try Again": start over with the chosen VPN (leaves a backup, forgets what failed here).
    func retryVPN() {
        guard !isPreview else { return }
        failedHere = []
        if backupVPNID != nil { switchActive(to: nil) }
        connectVPN()
    }

    func disconnectVPN() {
        guard !isPreview else { return }
        userStoppedVPN = true
        vpnStartedByUs = false
        stopSelectedVPN()
    }

    /// Starts the VPN in use (the chosen one, or the backup).
    private func startSelectedVPN() {
        if let v = activeVPN, v.engine == .wireGuard, let id = v.tunnelID {
            perform(.wgConnect(id: id))
        } else {
            vpn.start()
        }
    }

    private func stopSelectedVPN() {
        lastStopRequest = Date()
        if activeVPN?.engine == .wireGuard {
            perform(.wgDisconnect)
        } else {
            stoppingVPN = true
            vpn.stop()
        }
    }

    /// Takes a VPN down by its id, whatever the watcher points at. Asks macOS, not the watcher:
    /// right after a switch its state can still be "disconnected" while the old VPN is connecting
    /// (bug: it kept connecting after a fast switch).
    private func stopVPN(id: String?, replacedBy new: String?) {
        guard let id else { return }
        lastStopRequest = Date()
        if Self.isWireGuardID(id) {
            // Going to another WireGuard VPN: "connect" swaps the tunnel, no separate "disconnect".
            if status?.config.wgActive != nil, !Self.isWireGuardID(new) { perform(.wgDisconnect) }
        } else {
            VPNConnection.stopService(id)
        }
    }

    // MARK: - Network quality

    /// Is a VPN needed here right now (untrusted network, protection on)?
    var vpnNeededNow: Bool {
        guard let s = status else { return false }
        return AutoVPN.wantsVPN(mode: s.mode, reason: s.reason, resolvingFor: resolvingSince.map { Self.awake - $0 } ?? 0,
                                primaryTrusted: primaryLink?.trustedName != nil)
    }

    /// Where the Mac is and what its traffic goes through, for the quality checks. Nil: no network.
    var qualityContext: QualityContext? {
        guard helperReady, let s = status, let link = primaryLink else { return nil }
        let up = vpnState == .connected
        // Normal internet here: trusted, paused, protection off, or a trusted card in use.
        let open = s.mode == .open || mixedUsesTrusted
        let via: String? = up ? (activeVPN?.name ?? "VPN") : (open ? QualityVia.noVPN : nil)
        return QualityContext(network: link.trustedName ?? Self.kindName(link), via: via,
                              serverIP: up ? serverIP(of: activeVPN) : nil, card: link.interface, cardLabel: link.label,
                              routerIP: link.routerIP, vpnName: activeVPN?.name ?? selectedVPN?.name,
                              directAllowed: open, paused: s.reason == .paused, trusted: link.trustedName != nil)
    }

    /// The VPN server's IPv4 address (looked up by the helper for host names).
    func serverIP(of v: VPNService?) -> String? {
        guard let v else { return nil }
        let host = v.engine == .wireGuard ? (tunnel(for: v)?.endpointHost ?? "") : GuardConfig.normalizeServer(v.remoteAddress ?? "")
        if Net.isIPv4(host) { return host }
        return status?.config.hostIPs[host]?.first
    }

    /// VPNs Compare VPNs can measure: they must carry all traffic.
    var comparableVPNs: [VPNService] {
        vpnServices.filter { !$0.isPartial && !$0.isOtherApp && !$0.needsSendAllFix }
    }

    /// A Network Quality test: use this VPN now, or no VPN (`QualityMonitor.noVPNID`, only where normal
    /// internet is allowed); nil: back to the normal one. The lock stays as it is.
    func compareSwitch(to id: String?) {
        guard !isPreview, id != comparingVPNID else { return }
        let noVPN = QualityMonitor.noVPNID
        let old = comparingVPNID == noVPN ? nil : activeVPNID
        let new = id == noVPN ? nil : (id ?? backupVPNID ?? selectedVPNID)
        switchingVPN = true
        if old != new { stopVPN(id: old, replacedBy: new) }
        comparingVPNID = id
        attemptOpen = false
        wgConnectingSince = nil
        autoStartAttempts = 0
        lastAutoStart = .distantPast
        vpnConnectedOn = nil
        if old != new { vpn.watch(serviceID: new == nil || Self.isWireGuardID(new) ? nil : new) }
        switchingVPN = false
        if id == noVPN { return }
        if id != nil {
            if vpnState != .connected {
                vpnStartedByUs = true
                startSelectedVPN()
            }
        } else {
            runAutoVPN()   // the chosen VPN again where one is needed
        }
    }

    /// After Compare VPNs on a network that needs no VPN: take down the one it left running.
    func stopVPNAfterCompare() {
        guard !isPreview, comparingVPNID == nil, !vpnNeededNow, vpnState.isUp else { return }
        vpnStartedByUs = false
        stopSelectedVPN()
    }

    /// Notes when the VPN is needed, comes up and goes down, for "VPN today".
    private func trackQuality() {
        guard !isPreview, helperReady, status != nil else { return }
        let now = Date()
        let needed = vpnNeededNow
        let state = vpnState
        let up = state == .connected
        if state == .connecting, connectingSince == nil { connectingSince = now }
        let place = qualityContext?.network
        if needed != qualityNeeded {
            qualityNeeded = needed
            quality.note(VPNEvent(at: now, kind: needed ? .needed : .notNeeded, network: place))
        }
        if up != qualityUp {
            qualityUp = up
            if up {
                let took = connectingSince.map { now.timeIntervalSince($0) }
                qualityUpName = activeVPN?.name
                quality.note(VPNEvent(at: now, kind: .up, seconds: took.flatMap { $0 < 120 ? $0 : nil }, network: place,
                                      vpn: qualityUpName))
            } else {
                let onPurpose = now.timeIntervalSince(lastStopRequest) < 15 || userStoppedVPN || comparingVPNID != nil
                    || !needed
                quality.note(VPNEvent(at: now, kind: onPurpose ? .stopped : .dropped, network: place, vpn: qualityUpName))
            }
        }
        if state != .connecting { connectingSince = nil }
    }

    // MARK: - Failed connections and backup VPNs

    /// Use another VPN on this network (a backup), or nil to go back to the chosen one.
    private func switchActive(to backup: String?) {
        guard backup != backupVPNID else { return }
        let old = activeVPNID
        switchingVPN = true
        stopVPN(id: old, replacedBy: backup ?? selectedVPNID)
        backupVPNID = backup
        attemptOpen = false
        failedTries = 0
        wgConnectingSince = nil
        autoStartAttempts = 0
        lastAutoStart = .distantPast
        vpnConnectedOn = nil
        // The watcher reports the new VPN's state at once, which runs the automatic VPN again.
        vpn.watch(serviceID: Self.isWireGuardID(activeVPNID) ? nil : activeVPNID)
        switchingVPN = false
    }

    private func forgetFailures() {
        failedTries = 0
        failedHere = []
        attemptOpen = false
        wgConnectingSince = nil
    }

    /// A macOS VPN changed state: note failed tries and read why.
    private func noteMacVPN(_ state: VPNState) {
        switch state {
        case .connecting:
            stoppingVPN = false
            if !attemptOpen {
                attemptOpen = true
                attemptStarted = Date()
            }
        case .connected:
            stoppingVPN = false
            attemptOpen = false
            autoStartAttempts = 0
            vpnCameUp()
        case .disconnected:
            let stoppedByUs = stoppingVPN
            stoppingVPN = false
            guard attemptOpen else { return }
            attemptOpen = false
            // Failed to connect: the server may have a new IP (home DDNS). No dialog, background.
            client.send(.lookUpServers) { _ in }
            guard !stoppedByUs, !userStoppedVPN, comparingVPNID == nil, let v = activeVPN, v.engine == .macOS else { return }
            failedTries += 1
            readFailure(of: v, since: attemptStarted)
        default:
            break
        }
    }

    private func vpnCameUp() {
        failedTries = 0
        wgConnectingSince = nil
        if let id = activeVPNID, vpnProblems[id] != nil { vpnProblems[id] = nil }
    }

    /// Why did macOS not connect this VPN? L2TP and PPTP write it to /var/log/ppp.log.
    private func readFailure(of v: VPNService, since: Date) {
        let id = v.id
        let server = v.remoteAddress
        let isPPP = AutoVPN.isPPP(kind: v.kind)
        let fallback = (isPPP ? vpn.lastCause.flatMap(VPNFailure.from(pppLastCause:)) : nil) ?? .unknown
        readingFailure = true
        // A moment for macOS to finish writing the log.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            var failure = fallback
            if isPPP, let text = Self.tail(ofFile: "/var/log/ppp.log", bytes: 64_000),
               let found = PPPLog.lastFailure(in: text, server: server, since: since) {
                failure = found
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.readingFailure = false
                if !(self.activeVPNID == id && self.vpnState == .connected) {
                    self.vpnProblems[id] = VPNProblem(failure: failure, at: Date())
                    self.quality.noteFailure(vpn: v.name, network: self.qualityContext?.network, reason: failure.label)
                }
                self.runAutoVPN()
            }
        }
    }

    nonisolated private static func tail(ofFile path: String, bytes: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// WireGuard has no "failed" event: connecting for too long counts as failed.
    private func noteWireGuard() {
        guard comparingVPNID == nil, let v = activeVPN, v.engine == .wireGuard else {
            wgConnectingSince = nil
            return
        }
        switch vpnState {
        case .connected:
            vpnCameUp()
        case .connecting:
            if wgConnectingSince == nil { wgConnectingSince = Date() }
            if let since = wgConnectingSince, Date().timeIntervalSince(since) >= BackupVPN.wireGuardPatience,
               failedTries < BackupVPN.triesBeforeBackup, !userStoppedVPN {
                failedTries = BackupVPN.triesBeforeBackup
                let failure = wgRuntime?.error.map(VPNFailure.message) ?? .wireGuardNoAnswer
                vpnProblems[v.id] = VPNProblem(failure: failure, at: Date())
                quality.noteFailure(vpn: v.name, network: qualityContext?.network, reason: failure.label)
            }
        default:
            wgConnectingSince = nil
        }
    }

    /// Three failed tries with the VPN in use: go to the next VPN that carries all traffic.
    /// When every backup failed too, go back to the chosen VPN and keep trying it.
    /// Returns true if it switched (the automatic VPN already ran again for the new one).
    private func switchToBackupIfNeeded() -> Bool {
        guard useBackupVPN, autoConnect, !userStoppedVPN, vpnState != .connected,
              failedTries >= BackupVPN.triesBeforeBackup, let current = activeVPNID else { return false }
        failedHere.insert(current)
        if let next = BackupVPN.next(main: selectedVPNID, failed: failedHere, candidates: backupCandidates.map(\.id)) {
            NSLog("VPN Guard: \(activeVPN?.name ?? current) failed \(failedTries) times, trying a backup VPN")
            if let failed = activeVPN?.name, let using = vpnServices.first(where: { $0.id == next })?.name {
                quality.noteBackup(failed: failed, using: using)
            }
            switchActive(to: next)
            return true
        }
        if backupVPNID != nil {
            NSLog("VPN Guard: every backup VPN failed, back to the chosen VPN")
            switchActive(to: nil)
            return true
        }
        return false
    }

    // MARK: - Notifications

    /// macOS shows its own question the first time (and again if it was closed without an answer).
    func askForNotifications() {
        guard !isPreview else { return }
        notifier.authorize { [weak self] _ in self?.refreshNotificationPermission() }
    }

    func refreshNotificationPermission() {
        guard !isPreview else { return }
        notifier.access { [weak self] access in self?.notificationAccess = access }
    }

    static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Seconds the Mac has been awake since it started (stands still during sleep).
    private static var awake: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Tell the user when the internet stays blocked, when a backup VPN is used, and when it is fine again.
    private func updateNotices() {
        guard !isPreview, helperReady, let s = status, comparingVPNID == nil else { return }
        let resolvingFor = resolvingSince.map { Self.awake - $0 } ?? 0
        let wants = AutoVPN.wantsVPN(mode: s.mode, reason: s.reason, resolvingFor: resolvingFor,
                                     primaryTrusted: primaryLink?.trustedName != nil)
        let situation: Notices.Situation
        if !wants || userStoppedVPN {
            situation = .quiet
        } else if vpnState == .connected {
            situation = backupVPNID != nil ? .backup : .protected
        } else {
            situation = .blocked
        }
        if situation == .blocked {
            if blockedSince == nil { blockedSince = Self.awake }
        } else {
            blockedSince = nil
        }
        if situation == .quiet {
            lastNotice = nil
            return
        }
        // Wait for the reason, so the notification can say it.
        if situation == .blocked, readingFailure { return }
        let blockedFor = blockedSince.map { Self.awake - $0 } ?? 0
        guard let notice = Notices.decide(situation: situation, blockedFor: blockedFor, failedTries: failedTries,
                                          lastSent: lastNotice) else { return }
        lastNotice = notice
        guard notifyWhenBlocked else { return }
        let text = Notices.text(notice, vpn: activeVPN?.name, main: selectedVPN?.name,
                                reason: problem(for: activeVPN)?.failure)
        notifier.send(title: text.title, body: text.body)
    }

    // MARK: - WireGuard VPNs

    /// Sends a new WireGuard VPN to the helper and selects it. `done` gets an error message or nil.
    func addWireGuard(_ tunnel: WireGuardTunnel, privateKey: String, presharedKey: String?,
                      done: @escaping (String?) -> Void) {
        guard !isPreview else { done(nil); return }
        client.send(.wgAdd(tunnel: tunnel, privateKey: privateKey, presharedKey: presharedKey)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let s):
                    self.apply(.success(s))
                    let added = s.config.wireguard.first { $0.id == tunnel.id }
                        ?? s.config.wireguard.first { $0.name.lowercased() == tunnel.name.trimmingCharacters(in: .whitespaces).lowercased() }
                    // A tunnel that only carries some addresses does not replace the chosen VPN by itself.
                    if let added, added.isFullTunnel || self.selectedVPNID == nil {
                        self.selectedVPNID = "wg:\(added.id.uuidString)"
                    }
                    done(nil)
                case .failure(let error):
                    done(error.localizedDescription)
                }
            }
        }
    }

    func removeWireGuard(_ service: VPNService) {
        guard let id = service.tunnelID,
              Dialogs.confirm(title: "Remove \"\(service.name)\"?",
                              message: "Its keys are deleted from this Mac. To use it again, you must add it again.",
                              button: "Remove") else { return }
        if selectedVPNID == service.id { selectedVPNID = nil }
        perform(.wgRemove(id: id))
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func openVPNSettings() {
        for link in ["x-apple.systempreferences:com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension",
                     "x-apple.systempreferences:com.apple.Network-Settings.extension"] {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Creating a VPN (configuration profile)

    static var profileFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VPNGuard-profiles", isDirectory: true)
    }

    /// Writes the profile (only this user can read it), opens it so macOS offers to install it,
    /// and waits for the new VPN to appear. The file is deleted after 10 minutes.
    func createVPN(_ draft: VPNProfileDraft) throws {
        let data = try draft.mobileconfig()
        let fm = FileManager.default
        try fm.createDirectory(at: Self.profileFolder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let safeName = String(draft.cleanName.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-"
        })
        let url = Self.profileFolder.appendingPathComponent("VPN Guard - \(safeName).mobileconfig")
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Self.openProfilesSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: url) }

        pendingVPNName = draft.cleanName
        pendingStarted = Date()
        pendingTimer?.invalidate()
        pendingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPendingVPN() }
        }
    }

    private func checkPendingVPN() {
        guard let name = pendingVPNName else { stopWaitingForVPN(); return }
        reloadVPNServices()
        if let service = vpnServices.first(where: { $0.name == name }) {
            selectedVPNID = service.id
            stopWaitingForVPN()
        } else if Date().timeIntervalSince(pendingStarted) > 900 {
            stopWaitingForVPN()
        }
    }

    func stopWaitingForVPN() {
        pendingTimer?.invalidate()
        pendingTimer = nil
        pendingVPNName = nil
    }

    static func openProfilesSettings() {
        for link in ["x-apple.systempreferences:com.apple.Profiles-Settings.extension",
                     "x-apple.systempreferences:com.apple.preferences.configurationprofiles"] {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - Automatic VPN

    /// Locked on an untrusted network -> start the VPN (with back-off). Also when the router's
    /// address stays unknown for 5 s (some links never show one).
    /// A PPP VPN whose network is gone -> restart it now (macOS would wait up to 80 s).
    /// Just arrived on a trusted network -> stop it once (you can start it again by hand).
    private func runAutoVPN() {
        autoVPNStep()
        updateNotices()
        trackQuality()
    }

    private func autoVPNStep() {
        guard !isPreview, helperReady, let s = status, selectedVPNID != nil, comparingVPNID == nil else { return }
        // The backup was removed meanwhile: back to the chosen VPN.
        if let b = backupVPNID, !vpnServices.contains(where: { $0.id == b }) {
            switchActive(to: nil)
            return
        }
        let key = s.links.map { "\($0.interface)=\($0.routerMAC ?? $0.routerIP)" }.joined(separator: ",")
        if key.isEmpty {
            if networkGoneSince == nil { networkGoneSince = Date() }
        } else if key != networkKey || networkGoneSince != nil {
            // Your Connect / Disconnect choice belongs to a place: forget it only at a new one, not
            // after a Wi-Fi blip or a short sleep (bug: a blip at the office disconnected your VPN).
            let goneFor = networkGoneSince.map { Date().timeIntervalSince($0) }
            let isNew = AutoVPN.isNewNetwork(key: key, lastKey: networkKey, goneFor: goneFor)
            if isNew {
                userStoppedVPN = false
                autoDisconnectDoneFor = nil
                // A new place: what failed elsewhere says nothing here, and the chosen VPN goes first again.
                failedHere = []
                vpnProblems = [:]
                lastNotice = nil
                blockedSince = nil
            }
            autoStartAttempts = 0
            lastAutoStart = .distantPast
            failedTries = 0
            wgConnectingSince = nil
            networkKey = key
            networkGoneSince = nil
            if isNew, backupVPNID != nil {
                switchActive(to: nil)
                return
            }
        }
        if s.reason == .resolving {
            if resolvingSince == nil {
                resolvingSince = Self.awake
                DispatchQueue.main.asyncAfter(deadline: .now() + AutoVPN.resolvingGrace + 0.2) { [weak self] in
                    self?.runAutoVPN()
                }
            }
        } else {
            resolvingSince = nil
        }
        if vpnState == .connected {
            if vpnConnectedOn == nil {
                vpnConnectedOn = Set(s.links.map(AutoVPN.linkKey))
                narrowVPNNetwork(status: s)
            }
        } else {
            vpnConnectedOn = nil
        }

        noteWireGuard()
        let resolvingFor = resolvingSince.map { Self.awake - $0 } ?? 0
        let wants = AutoVPN.wantsVPN(mode: s.mode, reason: s.reason, resolvingFor: resolvingFor,
                                     primaryTrusted: primaryLink?.trustedName != nil)
        // No VPN needed here any more and the backup is down: the chosen VPN is "the VPN" again.
        if !wants, backupVPNID != nil, !vpnState.isUp {
            switchActive(to: nil)
            return
        }
        if wants {
            if vpnState == .connected, let v = activeVPN, v.engine == .macOS, AutoVPN.isPPP(kind: v.kind),
               let on = vpnConnectedOn, AutoVPN.networkMovedAway(connectedOn: on, links: s.links) {
                NSLog("VPN Guard: the network under \(v.name) is gone, restarting it")
                vpnConnectedOn = nil
                autoStartAttempts = 0
                lastAutoStart = .distantPast
                stoppingVPN = true
                vpn.stop()   // the next state change starts it again on the new network
                return
            }
            if switchToBackupIfNeeded() { return }
            guard autoConnect, !userStoppedVPN, vpnState == .disconnected else { return }
            let delay = Self.retryDelays[min(autoStartAttempts, Self.retryDelays.count - 1)]
            let wait = delay - Date().timeIntervalSince(lastAutoStart)
            guard wait <= 0 else {
                // Try again exactly when the wait is over (the 10 s timer alone would be late).
                if !retryTimerSet {
                    retryTimerSet = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
                        self?.retryTimerSet = false
                        self?.runAutoVPN()
                    }
                }
                return
            }
            lastAutoStart = Date()
            autoStartAttempts += 1
            vpnStartedByUs = true
            // A VPN started here goes again when the network is trusted, also the same one as before
            // (woken at home, the router not read yet: locked for a moment).
            autoDisconnectDoneFor = nil
            startSelectedVPN()
        } else if AutoVPN.shouldStopOwnVPN(reason: s.reason) {
            // Protection off or paused: normal internet. Stop the VPN we started (bug: it stayed on).
            if vpnStartedByUs, vpnState.isUp { stopSelectedVPN() }
            vpnStartedByUs = false
        } else if s.mode == .open, s.reason == .trusted {
            guard autoDisconnect, autoDisconnectDoneFor != key else { return }
            autoDisconnectDoneFor = key
            if vpnState.isUp {
                stopSelectedVPN()
                vpnStartedByUs = false
            }
        }
    }

    /// With two networks up, find the one the macOS VPN really uses (the route to its server), so a
    /// restart happens when exactly that one goes away.
    private func narrowVPNNetwork(status s: GuardStatus) {
        guard let v = activeVPN, v.engine == .macOS, AutoVPN.isPPP(kind: v.kind), s.links.count > 1,
              let server = v.remoteAddress.map(GuardConfig.normalizeServer) else { return }
        guard let ip = Net.isIPv4(server) ? server : s.config.hostIPs[server]?.first, Net.isIPv4(ip) else { return }
        let fallback = vpnConnectedOn
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/route")
            p.arguments = ["-n", "get", "-inet", ip]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard let iface = Routes.interface(routeGet: text) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.vpnState == .connected, self.vpnConnectedOn == fallback else { return }
                let used = s.links.filter { $0.interface == iface }
                if !used.isEmpty { self.vpnConnectedOn = Set(used.map(AutoVPN.linkKey)) }
            }
        }
    }

    // MARK: - Helper install, onboarding, login item

    func installHelper() {
        guard !isPreview else { return }
        do {
            try HelperInstaller.install()
            helperState = .checking
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
        } catch HelperInstaller.Failure.cancelled {
        } catch {
            Dialogs.error("Install failed", error.localizedDescription)
        }
    }

    func uninstallHelper() {
        guard Dialogs.confirm(title: "Uninstall the helper?",
                              message: "The firewall rules are removed and the internet works normally everywhere. Your trusted networks are kept.",
                              button: "Uninstall") else { return }
        do {
            try HelperInstaller.uninstall()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
        } catch HelperInstaller.Failure.cancelled {
        } catch {
            Dialogs.error("Uninstall failed", error.localizedDescription)
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Keys.onboardingDone)
        // On by default: without the app nobody starts the VPN after a restart, and at a café there is
        // then no internet at all. Settings can turn it off.
        if !isPreview, SMAppService.mainApp.status != .enabled { launchAtLogin = true }
    }

    /// Previews have no real login item.
    var previewLaunchAtLogin = true

    /// Previews: other VPNs (the Network Quality previews compare several).
    func previewSetMacVPNs(_ list: [VPNService]) {
        guard isPreview else { return }
        macVPNServices = list
    }

    var launchAtLogin: Bool {
        get { isPreview ? previewLaunchAtLogin : SMAppService.mainApp.status == .enabled }
        set {
            guard !isPreview else { previewLaunchAtLogin = newValue; return }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Dialogs.error("Login item", error.localizedDescription)
            }
            objectWillChange.send()
        }
    }

    // MARK: - Previews (render the UI with made-up data, no helper)

    enum PreviewScenario: String, CaseIterable {
        case protected, wireguard, trusted, connecting, blocked, paused, off, setup, mixed, mixedPhone, officeTwo, partial
        /// The chosen VPN was refused; and the same with a backup VPN connected instead.
        case failed, backup
    }

    init(preview: PreviewScenario) {
        quality = QualityMonitor(preview: true)
        isPreview = true
        autoConnect = true
        autoDisconnect = true
        useBackupVPN = preview == .backup
        notifyWhenBlocked = true
        macVPNServices = [
            VPNService(id: "preview", name: "Office VPN", kind: "L2TP", remoteAddress: "vpn.example.com", sendsAllTraffic: true),
            VPNService(id: "preview-2", name: "Branch Office", kind: "L2TP", remoteAddress: "203.0.113.10",
                       sendsAllTraffic: false, account: "vpn"),
        ]
        selectedVPNID = "preview"

        let office = TrustedNetwork(name: "Office", routerMAC: "48:8f:5a:0b:11:20", routerIP: "192.168.88.1",
                                    addedAt: Date(timeIntervalSinceNow: -86400 * 20))
        let home = TrustedNetwork(name: "Home", routerMAC: "a4:91:b1:2c:7e:03", routerIP: "192.168.1.1",
                                  addedAt: Date(timeIntervalSinceNow: -86400 * 30))
        var config = GuardConfig(enabled: true, vpnServers: ["vpn.example.com"],
                                 hostIPs: ["vpn.example.com": ["198.51.100.20"]], trusted: [office, home])
        let hotspot = NetworkLink(interface: "en0", displayName: "Wi-Fi", address: "172.20.10.6",
                                  routerIP: "172.20.10.1", routerMAC: "9e:4a:01:7c:22:b5", dnsServers: ["172.20.10.1"])
        var officeLink = NetworkLink(interface: "en0", displayName: "Wi-Fi", address: "192.168.88.23",
                                     routerIP: "192.168.88.1", routerMAC: office.routerMAC, dnsServers: ["192.168.88.1", "1.1.1.1"])
        officeLink.trustedName = "Office"
        let iPhoneUSB = NetworkLink(interface: "en7", displayName: "iPhone USB", address: "172.20.10.2",
                                    routerIP: "172.20.10.1", routerMAC: "9e:4a:01:7c:22:b5", dnsServers: ["172.20.10.1"])
        var officeLAN = NetworkLink(interface: "en7", displayName: "USB 10/100/1000 LAN", address: "192.168.88.24",
                                    routerIP: "192.168.88.1", routerMAC: office.routerMAC, dnsServers: ["192.168.88.1", "1.1.1.1"])
        officeLAN.trustedName = "Office"
        var primary: String?

        var mode = GuardMode.locked
        var reason = GuardReason.untrusted
        var links = [hotspot]
        switch preview {
        case .protected:
            macVPNState = .connected
            macConnectedSince = Date(timeIntervalSinceNow: -12 * 60)
        case .trusted:
            mode = .open; reason = .trusted; links = [officeLink]; macVPNState = .disconnected
        case .connecting:
            macVPNState = .connecting
        case .blocked:
            macVPNState = .disconnected
        case .paused:
            mode = .open; reason = .paused; macVPNState = .disconnected
            config.pausedUntil = Date(timeIntervalSinceNow: 192)
            UserDefaults.standard.set(300.0, forKey: Keys.pauseLength)
        case .off:
            mode = .open; reason = .disabled; macVPNState = .disconnected; config.enabled = false
        case .wireguard:
            macVPNState = .disconnected
        case .setup:
            macVPNState = .disconnected
        case .mixed:
            reason = .mixed; links = [officeLink, iPhoneUSB]; primary = "en0"; macVPNState = .disconnected
        case .partial:
            macVPNState = .disconnected
        case .failed:
            macVPNState = .disconnected
            vpnProblems["preview"] = VPNProblem(failure: .loginRefused(code: 691), at: Date(timeIntervalSinceNow: -40))
            lastAutoStart = Date(timeIntervalSinceNow: -0.5)
            autoStartAttempts = 3
        case .backup:
            macVPNServices.append(VPNService(id: "preview-3", name: "Home VPN", kind: "L2TP", remoteAddress: "home.example.net",
                                             sendsAllTraffic: true))
            backupVPNID = "preview-3"
            vpnProblems["preview"] = VPNProblem(failure: .loginRefused(code: 691), at: Date(timeIntervalSinceNow: -150))
            macVPNState = .connected
            macConnectedSince = Date(timeIntervalSinceNow: -2 * 60)
        case .officeTwo:
            mode = .open; reason = .trusted; links = [officeLink, officeLAN]; primary = "en7"; macVPNState = .disconnected
        case .mixedPhone:
            reason = .mixed; links = [officeLink, iPhoneUSB]; primary = "en7"
            macVPNState = .connected
            macConnectedSince = Date(timeIntervalSinceNow: -3 * 60)
        }
        var wgRuntime: WireGuardRuntime?
        if preview == .partial {
            let officeWG = WireGuardTunnel(name: "Office tunnel", publicKey: "Wq7sZ9cH1pYk3QeV0aTn5RbX8uLm2DjF6gKw4yNo0Es=",
                                           addresses: ["192.168.88.222/32"], dns: ["1.1.1.1"],
                                           peerPublicKey: "kP5mW2xQ8rT1vY6nB3cJ9hL4fD7sA0gE5uI2oK8zXqM=",
                                           endpoint: "vpn.example.com:51820", allowedIPs: ["192.168.88.0/24"])
            config.wireguard = [officeWG]
            config.wgActive = officeWG.id
            selectedVPNID = "wg:\(officeWG.id.uuidString)"
            wgRuntime = WireGuardRuntime(tunnelID: officeWG.id, interface: "utun9", startedAt: Date(timeIntervalSinceNow: -3 * 60),
                                         lastHandshake: Date(timeIntervalSinceNow: -5), rxBytes: 92, txBytes: 180)
        }
        if preview == .wireguard {
            let home = WireGuardTunnel(name: "Home", publicKey: "Wq7sZ9cH1pYk3QeV0aTn5RbX8uLm2DjF6gKw4yNo0Es=",
                                       addresses: ["10.8.0.2/32"], dns: ["1.1.1.1"],
                                       peerPublicKey: "kP5mW2xQ8rT1vY6nB3cJ9hL4fD7sA0gE5uI2oK8zXqM=",
                                       endpoint: "home.example.net:51820")
            config.wireguard = [home]
            config.wgActive = home.id
            selectedVPNID = "wg:\(home.id.uuidString)"
            wgRuntime = WireGuardRuntime(tunnelID: home.id, interface: "utun9", startedAt: Date(timeIntervalSinceNow: -12 * 60),
                                         lastHandshake: Date(timeIntervalSinceNow: -8), rxBytes: 24_100_000, txBytes: 3_100_000)
        }
        if preview == .setup {
            helperState = .notInstalled
            status = nil
        } else {
            helperState = .ready
            status = GuardStatus(mode: mode, reason: reason, links: links, config: config, firewallError: nil,
                                 helperVersion: VG.version, updatedAt: Date(), wg: wgRuntime,
                                 primaryInterface: primary ?? links.first?.interface)
        }
    }
}

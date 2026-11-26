import AppKit
import Foundation
import notify
import ServiceManagement
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

    var title: String {
        switch self {
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

/// One network card in the popover.
struct NetworkCardInfo: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let trusted: Bool?
    var pill: String = ""
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

    @Published var selectedVPNID: String? {
        didSet {
            guard selectedVPNID != oldValue, !isPreview else { return }
            UserDefaults.standard.set(selectedVPNID, forKey: Keys.vpnServiceID)
            // One VPN at a time: take the old one down first (the watcher still points at it),
            // then watch the new choice.
            if Self.isWireGuardID(oldValue), status?.config.wgActive != nil { perform(.wgDisconnect) }
            // Ask macOS, not the watcher: right after a switch its state can still be "disconnected"
            // while the old VPN is connecting (bug: it kept connecting after a fast switch).
            if let old = oldValue, !Self.isWireGuardID(old) { VPNConnection.stopService(old) }
            vpn.watch(serviceID: Self.isWireGuardID(selectedVPNID) ? nil : selectedVPNID)
            syncVPNServers()
        }
    }
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect); runAutoVPN() }
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
        static let onboardingDone = "onboardingDone"
        static let pauseLength = "pauseLength"
    }

    private let client = HelperClient()
    private let vpn = VPNConnection()
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID
    private var timer: Timer?
    private var isPreview = false

    // Auto VPN bookkeeping, reset whenever the network changes.
    private var networkKey = ""
    private var userStoppedVPN = false
    private var autoDisconnectDoneFor: String?
    private var lastAutoStart = Date.distantPast
    private var autoStartAttempts = 0
    /// When the router's hardware address started to be unknown (reason "resolving").
    private var resolvingSince: Date?
    /// The networks (card, address, router) the macOS VPN connected on.
    private var vpnConnectedOn: Set<String>?
    /// When the last network went away (a Wi-Fi blip or sleep keeps your VPN choice, see AutoVPN).
    private var networkGoneSince: Date?

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
        let d = UserDefaults.standard
        d.register(defaults: [Keys.autoConnect: true, Keys.autoDisconnect: true])
        selectedVPNID = d.string(forKey: Keys.vpnServiceID)
        autoConnect = d.bool(forKey: Keys.autoConnect)
        autoDisconnect = d.bool(forKey: Keys.autoDisconnect)

        // Profiles hold a password: never leave old ones lying around.
        try? FileManager.default.removeItem(at: Self.profileFolder)

        reloadVPNServices()
        vpn.onChange = { [weak self] state in
            guard let self else { return }
            let previous = self.macVPNState
            if state == .connected, self.macVPNState != .connected { self.macConnectedSince = Date() }
            if state != .connected { self.macConnectedSince = nil }
            self.macVPNState = state
            if state == .connected { self.autoStartAttempts = 0 }
            if state == .disconnected, previous == .connecting {
                // Failed to connect: the server may have a new IP (home DDNS). No dialog, background.
                self.client.send(.lookUpServers) { _ in }
            }
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
        refresh()
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
                       sendsAllTraffic: t.isFullTunnel, engine: .wireGuard, tunnelID: t.id)
        }
    }

    var vpnServices: [VPNService] { wireGuardServices + macVPNServices }
    var selectedVPN: VPNService? { vpnServices.first { $0.id == selectedVPNID } }

    func tunnel(for service: VPNService?) -> WireGuardTunnel? {
        guard let id = service?.tunnelID else { return nil }
        return status?.config.wireguard.first { $0.id == id }
    }

    /// The helper's tunnel, if it is the selected VPN.
    var wgRuntime: WireGuardRuntime? {
        guard let id = selectedVPN?.tunnelID, let rt = status?.wg, rt.tunnelID == id else { return nil }
        return rt
    }

    var vpnState: VPNState {
        guard let v = selectedVPN else { return selectedVPNID == nil ? .none : .invalid }
        guard v.engine == .wireGuard else { return macVPNState }
        guard status?.config.wgActive == v.tunnelID else { return .disconnected }
        return wgRuntime?.isConnected() == true ? .connected : .connecting
    }

    var vpnConnectedSince: Date? {
        guard selectedVPN?.engine == .wireGuard else { return macConnectedSince }
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
        let vpnName = selectedVPN?.name ?? "your VPN"
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
        if selectedVPN == nil {
            return StateLook(glyph: .cross, tone: .orange, title: "Blocked",
                             subtitle: "Choose the VPN to use on networks you don't trust.", primary: .chooseVPN)
        }
        switch vpnState {
        case .connected:
            return StateLook(glyph: .lock, tone: .green, title: "Protected", subtitle: protected)
        case .connecting:
            return StateLook(glyph: .dots, tone: .orange, title: "Connecting…",
                             subtitle: "Starting \(vpnName). The internet opens as soon as it is up.",
                             primary: .connecting, pulsing: true)
        default:
            return StateLook(glyph: .cross, tone: .orange, title: "Blocked",
                             subtitle: "The VPN is off, so nothing on this Mac can reach the internet here.", primary: .connectVPN)
        }
    }

    var networkCards: [NetworkCardInfo] {
        guard let s = status else { return [] }
        if s.links.isEmpty {
            return [NetworkCardInfo(id: "none", symbol: "wifi.slash", title: "No network", detail: "Not connected", trusted: nil)]
        }
        let several = s.links.count > 1
        return s.links.map { link in
            let hotspot = TrustPick.isPhoneHotspot(link)
            let kind = Self.kindName(link)
            let inUse = several && link.interface == s.primaryInterface ? " · in use" : ""
            if let name = link.trustedName {
                return NetworkCardInfo(id: link.interface, symbol: Self.symbol(forTrustedName: name), title: name,
                                       detail: "\(kind) · \(link.routerIP)\(inUse)", trusted: true, pill: pillText(for: link))
            }
            return NetworkCardInfo(id: link.interface, symbol: Self.symbol(for: link, hotspot: hotspot), title: kind,
                                   detail: "Router \(link.routerIP)\(inUse)", trusted: false, pill: pillText(for: link))
        }
    }

    static func symbol(for link: NetworkLink, hotspot: Bool) -> String {
        if hotspot || link.label.localizedCaseInsensitiveContains("iphone") { return "personalhotspot" }
        if link.label.localizedCaseInsensitiveContains("wi-fi") || link.label.localizedCaseInsensitiveContains("wi‑fi") { return "wifi" }
        if link.label.localizedCaseInsensitiveContains("ethernet") || link.label.localizedCaseInsensitiveContains("thunderbolt") {
            return "cable.connector.horizontal"
        }
        return "network"
    }

    static func symbol(forTrustedName name: String) -> String {
        let n = name.lowercased()
        if ["home", "nhà", "house"].contains(where: n.contains) { return "house" }
        if ["office", "văn phòng", "work", "công ty", "vp"].contains(where: n.contains) { return "building.2" }
        return "wifi"
    }

    /// One line under the VPN name. `now` comes from a TimelineView, so the minutes tick.
    func vpnDetail(now: Date) -> String {
        guard let vpn = selectedVPN else { return "Choose the VPN to use" }
        let server = vpn.remoteAddress ?? ""
        if vpn.engine == .wireGuard {
            let rt = wgRuntime
            switch vpnState {
            case .connected:
                let since = vpnConnectedSince.map { Self.duration(now.timeIntervalSince($0)) } ?? "just now"
                let traffic = rt.map { "↓ \(Self.bytes($0.rxBytes)) ↑ \(Self.bytes($0.txBytes))" } ?? ""
                return [since == "just now" ? "Connected just now" : since, traffic].filter { !$0.isEmpty }.joined(separator: " · ")
            case .connecting:
                if let e = rt?.error { return e }
                if rt?.isRunning == true { return "Waiting for \(server) to answer…" }
                return "Connecting to \(server)…"
            default:
                return vpnNotNeeded ?? "WireGuard · Disconnected"
            }
        }
        switch vpnState {
        case .connected:
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
            return vpnNotNeeded ?? "Disconnected"
        }
    }

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
            status = s
            helperState = s.helperVersion == VG.version ? .ready : .outdated(s.helperVersion)
            syncVPNServers()
            runAutoVPN()
        case .failure(let error):
            status = nil
            helperState = Self.helperInstalledOnDisk ? .notResponding(error.localizedDescription) : .notInstalled
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
            UserDefaults.standard.set(merged.auto, forKey: Keys.autoServers)
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
        macVPNServices = VPNCatalog.services()
        syncVPNServers()
    }

    func connectVPN() {
        guard !isPreview else { return }
        userStoppedVPN = false
        if selectedVPN?.engine == .wireGuard {
            startSelectedVPN()
            return
        }
        if !vpn.start() {
            Dialogs.error("VPN did not start", "macOS refused to start \"\(selectedVPN?.name ?? "the VPN")\". Try it once from System Settings → VPN so the password is saved.")
        }
    }

    func disconnectVPN() {
        guard !isPreview else { return }
        userStoppedVPN = true
        stopSelectedVPN()
    }

    private func startSelectedVPN() {
        if let v = selectedVPN, v.engine == .wireGuard, let id = v.tunnelID {
            perform(.wgConnect(id: id))
        } else {
            vpn.start()
        }
    }

    private func stopSelectedVPN() {
        if selectedVPN?.engine == .wireGuard {
            perform(.wgDisconnect)
        } else {
            vpn.stop()
        }
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
                    if let added { self.selectedVPNID = "wg:\(added.id.uuidString)" }
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
        guard !isPreview, helperReady, let s = status, selectedVPNID != nil else { return }
        let key = s.links.map { "\($0.interface)=\($0.routerMAC ?? $0.routerIP)" }.joined(separator: ",")
        if key.isEmpty {
            if networkGoneSince == nil { networkGoneSince = Date() }
        } else if key != networkKey || networkGoneSince != nil {
            // Your Connect / Disconnect choice belongs to a place: forget it only at a new one, not
            // after a Wi-Fi blip or a short sleep (bug: a blip at the office disconnected your VPN).
            let goneFor = networkGoneSince.map { Date().timeIntervalSince($0) }
            if AutoVPN.isNewNetwork(key: key, lastKey: networkKey, goneFor: goneFor) {
                userStoppedVPN = false
                autoDisconnectDoneFor = nil
            }
            autoStartAttempts = 0
            lastAutoStart = .distantPast
            networkKey = key
            networkGoneSince = nil
        }
        if s.reason == .resolving {
            if resolvingSince == nil {
                resolvingSince = Date()
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

        let resolvingFor = resolvingSince.map { Date().timeIntervalSince($0) } ?? 0
        if AutoVPN.wantsVPN(mode: s.mode, reason: s.reason, resolvingFor: resolvingFor,
                            primaryTrusted: primaryLink?.trustedName != nil) {
            if vpnState == .connected, let v = selectedVPN, v.engine == .macOS, AutoVPN.isPPP(kind: v.kind),
               let on = vpnConnectedOn, AutoVPN.networkMovedAway(connectedOn: on, links: s.links) {
                NSLog("VPN Guard: the network under \(v.name) is gone, restarting it")
                vpnConnectedOn = nil
                autoStartAttempts = 0
                lastAutoStart = .distantPast
                vpn.stop()   // the next state change starts it again on the new network
                return
            }
            guard autoConnect, !userStoppedVPN, vpnState == .disconnected else { return }
            let delays: [TimeInterval] = [0, 5, 15, 30, 60]
            guard Date().timeIntervalSince(lastAutoStart) >= delays[min(autoStartAttempts, delays.count - 1)] else { return }
            lastAutoStart = Date()
            autoStartAttempts += 1
            startSelectedVPN()
        } else if s.mode == .open, s.reason == .trusted {
            guard autoDisconnect, autoDisconnectDoneFor != key else { return }
            autoDisconnectDoneFor = key
            if vpnState.isUp { stopSelectedVPN() }
        }
    }

    /// With two networks up, find the one the macOS VPN really uses (the route to its server), so a
    /// restart happens when exactly that one goes away.
    private func narrowVPNNetwork(status s: GuardStatus) {
        guard let v = selectedVPN, v.engine == .macOS, AutoVPN.isPPP(kind: v.kind), s.links.count > 1,
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
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
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
        case protected, wireguard, trusted, connecting, blocked, paused, off, setup, mixed, mixedPhone
    }

    init(preview: PreviewScenario) {
        isPreview = true
        autoConnect = true
        autoDisconnect = true
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
                                  routerIP: "172.20.10.1", routerMAC: "9e:4a:01:7c:22:b5")
        var officeLink = NetworkLink(interface: "en0", displayName: "Wi-Fi", address: "192.168.88.23",
                                     routerIP: "192.168.88.1", routerMAC: office.routerMAC)
        officeLink.trustedName = "Office"
        let iPhoneUSB = NetworkLink(interface: "en7", displayName: "iPhone USB", address: "172.20.10.2",
                                    routerIP: "172.20.10.1", routerMAC: "9e:4a:01:7c:22:b5")
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
        case .mixedPhone:
            reason = .mixed; links = [officeLink, iPhoneUSB]; primary = "en7"
            macVPNState = .connected
            macConnectedSince = Date(timeIntervalSinceNow: -3 * 60)
        }
        var wgRuntime: WireGuardRuntime?
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

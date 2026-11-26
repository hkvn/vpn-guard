import Foundation
import SystemConfiguration
import notify
import VPNGuardCore

/// The helper's brain. Everything runs on one serial queue.
///
/// Flow: a network change event from configd -> read the routers -> decide (Policy) ->
/// load or clear the pf anchor -> post a Darwin notification so the app updates its icon.
/// A 30 s safety timer also checks that nobody removed our rules or turned pf off.
final class Engine {
    let queue = DispatchQueue(label: "local.vpnguard.engine")

    private let configStore = ConfigStore()
    private let firewall = Firewall()
    private let dnsServer = PinnedDNSServer()
    private lazy var wg = WireGuardManager(queue: queue)
    private let wgKeys = WireGuardKeyStore()
    private var wgError: String?
    private var wgRetryAt = Date.distantPast
    private var wgFailures = 0
    private var config: GuardConfig
    private var dynamicStore: SCDynamicStore?

    private var appliedMode: GuardMode?
    private var appliedRules: String?
    private var firewallError: String?
    /// Set if pfctl ever rejects the DNS lookup rule: from then on we lock without it.
    private var dnsRuleRejected = false
    /// True only while the helper's own server lookup runs: then lock mode lets DNS out from
    /// `VG.dnsLookupPort` (and nothing else). Closed again when the lookup is done.
    private var dnsWindowOpen = false
    /// Links of the latest evaluation (the published status can be one step behind).
    private var currentLinks: [NetworkLink] = []
    private(set) var status: GuardStatus
    private var hasPublished = false

    private var safetyTimer: DispatchSourceTimer?
    private var pauseTimer: DispatchSourceTimer?
    private var pauseTimerTarget: Date?

    // Router MAC lookup (ping once so the kernel fills its ARP table), with back-off.
    private var lookupAttempts: [String: (count: Int, last: Date)] = [:]
    private var lookupsRunning = Set<String>()
    private var lookupRetryScheduled = false

    // VPN server host names -> IPs.
    private var hostRefreshRunning = false
    private var hostRefreshPending = false
    private var lastLookupProblem: String?
    private var lastHostRefresh = Date.distantPast

    static let safetyInterval: TimeInterval = 30

    init() {
        config = configStore.load()
        status = GuardStatus(mode: .open, reason: .disabled, links: [], config: config,
                             firewallError: nil, helperVersion: VG.version, updatedAt: Date())
    }

    func start() {
        queue.sync {
            Log.info("VPN Guard helper \(VG.version) starting")
            firewall.enable()
            if !firewall.hasAnchorPoint() {
                Log.info("pf main ruleset has no com.apple anchor point, reloading /etc/pf.conf")
                firewall.reloadMainRuleset()
            }
            watchNetwork()
            wg.cleanUp(store: dynamicStore)
            wg.onExit = { [weak self] in
                guard let self else { return }
                Log.error("WireGuard engine stopped")
                self.wgError = "The WireGuard engine stopped. Starting it again…"
                self.wgRetryAt = Date().addingTimeInterval(2)
                self.queue.asyncAfter(deadline: .now() + 2.1) { [weak self] in self?.evaluate("wireguard exited") }
            }
            dnsServer.start()
            syncPinnedNames()
            evaluate("start")
            refreshHosts(force: true)
            startSafetyTimer()
        }
    }

    // MARK: - Network events

    private func watchNetwork() {
        var ctx = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                        retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<Engine>.fromOpaque(info).takeUnretainedValue().evaluate("network change")
        }
        guard let store = SCDynamicStoreCreate(nil, VG.helperLabel as CFString, callback, &ctx) else {
            Log.error("SCDynamicStoreCreate failed; only the safety timer will run")
            return
        }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Interface"] as CFArray
        let patterns = [
            "State:/Network/Service/[^/]+/IPv4",
            "State:/Network/Service/[^/]+/DNS",
            "State:/Network/Interface/[^/]+/IPv4",
            "State:/Network/Interface/[^/]+/Link",
        ] as CFArray
        if !SCDynamicStoreSetNotificationKeys(store, keys, patterns) || !SCDynamicStoreSetDispatchQueue(store, queue) {
            Log.error("Could not subscribe to network changes")
        }
        dynamicStore = store
    }

    private func startSafetyTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(wallDeadline: .now() + Self.safetyInterval, repeating: Self.safetyInterval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.safetyCheck() }
        t.resume()
        safetyTimer = t
    }

    /// Re-checks the network, then makes sure the lock is really in place.
    private func safetyCheck() {
        evaluate("timer")
        refreshHosts()
        guard appliedMode == .locked else { return }
        var broken: [String] = []
        if !firewall.isEnabled() { broken.append("pf was turned off"); firewall.enable() }
        if !firewall.hasAnchorPoint() { broken.append("anchor point missing"); firewall.reloadMainRuleset() }
        if firewall.loadedRuleCount() == 0 { broken.append("our rules were removed") }
        if !broken.isEmpty {
            Log.error("Repairing firewall: \(broken.joined(separator: ", "))")
            appliedMode = nil
            appliedRules = nil
            evaluate("repair")
        }
    }

    // MARK: - Decide and apply

    func evaluate(_ why: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let now = Date()
        if let until = config.pausedUntil, until <= now {
            config.pausedUntil = nil
            persist()
        }

        var links = NetworkProbe.links(store: dynamicStore)
        for i in links.indices where links[i].routerMAC == nil {
            links[i].routerMAC = ARPTable.lookup(ip: links[i].routerIP, interface: links[i].interface)
        }
        for i in links.indices {
            links[i].trustedName = config.trustedNetwork(matchingMAC: links[i].routerMAC)?.name
        }

        currentLinks = links
        let decision = Policy.decide(config: config, links: links, now: now)
        let modeBefore = appliedMode
        apply(decision.mode, links: links)
        // Locked or unlocked just now: check the VPN server names at once (bug: up to 45 s wait).
        if modeBefore != nil, appliedMode != modeBefore { refreshHosts(force: true) }
        // After apply(): the firewall already lets the WireGuard server through.
        ensureWireGuard(links: links)
        // After apply(): in lock mode the ping to the router is only allowed once the rules include it.
        lookUpMissingRouters(links)
        schedulePauseEnd()
        publish(decision, links: links, why: why)
    }

    private func apply(_ mode: GuardMode, links: [NetworkLink]) {
        switch mode {
        case .open:
            guard appliedMode != .open else { return }
            if let err = firewall.clear() {
                firewallError = err
                Log.error(err)
                return
            }
            appliedMode = .open
            appliedRules = nil
            firewallError = nil

        case .locked:
            func rules(withDNS: Bool) -> String {
                PFRules.lockRules(vpnServers: config.allowedIPs,
                                  routers: links.map(\.routerIP),
                                  interfaces: Interfaces.names(),
                                  dnsLookupPort: withDNS ? VG.dnsLookupPort : nil)
            }
            var wanted = rules(withDNS: dnsWindowOpen && !dnsRuleRejected)
            guard appliedMode != .locked || wanted != appliedRules else { return }
            if !firewall.isEnabled() { firewall.enable() }
            var loadError = firewall.load(wanted)
            if let err = loadError, !dnsRuleRejected {
                // Never let the extra rule cost us the lock itself.
                Log.error("pf rejected the lock rules with the DNS lookup rule (\(err)); locking without it")
                dnsRuleRejected = true
                wanted = rules(withDNS: false)
                loadError = firewall.load(wanted)
            }
            if let err = loadError {
                firewallError = err
                Log.error(err)
                return
            }
            let rules = wanted
            let wasLocked = appliedMode == .locked
            appliedMode = .locked
            appliedRules = rules
            firewallError = nil
            if !wasLocked { firewall.flushStates() }
        }
    }

    private func lookUpMissingRouters(_ links: [NetworkLink]) {
        let missing = links.filter { $0.routerMAC == nil }
        let current = Set(missing.map(\.routerIP))
        lookupAttempts = lookupAttempts.filter { current.contains($0.key) }

        let now = Date()
        var nextRetry: TimeInterval?
        for link in missing where !lookupsRunning.contains(link.routerIP) {
            let ip = link.routerIP, ifname = link.interface
            let attempt = lookupAttempts[ip] ?? (0, .distantPast)
            let wait = min(30, pow(2, Double(attempt.count)) - 1) // 0, 1, 3, 7, 15, 30 s
            let remaining = wait - now.timeIntervalSince(attempt.last)
            if remaining > 0 {
                nextRetry = min(nextRetry ?? remaining, remaining)
                continue
            }
            lookupAttempts[ip] = (attempt.count + 1, now)
            lookupsRunning.insert(ip)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                Shell.run("/sbin/ping", ["-n", "-q", "-c", "1", "-t", "1", "-b", ifname, ip])
                self?.queue.async {
                    self?.lookupsRunning.remove(ip)
                    self?.evaluate("router lookup")
                }
            }
            // The ARP answer usually comes long before ping gives up.
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.evaluate("router lookup") }
        }
        if let nextRetry, !lookupRetryScheduled {
            lookupRetryScheduled = true
            queue.asyncAfter(deadline: .now() + nextRetry + 0.05) { [weak self] in
                self?.lookupRetryScheduled = false
                self?.evaluate("router lookup retry")
            }
        }
    }

    private func schedulePauseEnd() {
        let target = config.enabled ? config.pausedUntil : nil
        guard target != pauseTimerTarget else { return }
        pauseTimer?.cancel()
        pauseTimer = nil
        pauseTimerTarget = target
        guard let target else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Wall clock, so a pause still ends on time after the Mac sleeps.
        t.schedule(wallDeadline: .now() + max(0, target.timeIntervalSinceNow) + 0.05)
        t.setEventHandler { [weak self] in self?.evaluate("pause ended") }
        t.resume()
        pauseTimer = t
    }

    private func publish(_ decision: (mode: GuardMode, reason: GuardReason), links: [NetworkLink], why: String) {
        var next = GuardStatus(mode: decision.mode, reason: decision.reason, links: links, config: config,
                               firewallError: firewallError, helperVersion: VG.version, updatedAt: status.updatedAt,
                               wg: wgRuntime())
        if next.firewallError == nil, let applied = appliedMode, applied != decision.mode {
            next.firewallError = "The firewall is not in the wanted state yet."
        }
        guard !hasPublished || Self.comparable(next) != Self.comparable(status) else {
            status.wg = next.wg
            return
        }
        let stateChanged = !hasPublished || next.mode != status.mode || next.reason != status.reason
        next.updatedAt = Date()
        status = next
        hasPublished = true
        if stateChanged {
            let where_ = links.map { "\($0.interface) router \($0.routerIP) \($0.routerMAC ?? "?")\($0.trustedName.map { " [\($0)]" } ?? "")" }
            Log.info("\(next.mode.rawValue.uppercased()) (\(next.reason.rawValue)) after \(why); \(where_.isEmpty ? "no networks" : where_.joined(separator: ", "))")
        }
        notify_post(VG.statusNotification)
    }

    /// The status without values that change all the time (byte counters).
    private static func comparable(_ s: GuardStatus) -> GuardStatus {
        var c = s
        c.wg = s.wg?.withoutCounters
        return c
    }

    // MARK: - WireGuard

    /// Keeps the wanted WireGuard tunnel up, or takes it down. Called at the end of every evaluate.
    private func ensureWireGuard(links: [NetworkLink]) {
        guard let id = config.wgActive, let tunnel = config.wireguard.first(where: { $0.id == id }) else {
            if wg.tunnelID != nil || wg.isRunning {
                wg.down(store: dynamicStore)
                Log.info("WireGuard down")
            }
            wgError = nil
            return
        }
        let gateway = links.first?.routerIP
        let endpointIP = Net.isIPv4(tunnel.endpointHost) ? tunnel.endpointHost : config.hostIPs[tunnel.endpointHost]?.first
        if wg.isRunning, wg.tunnelID == id, endpointIP == nil || endpointIP == wg.endpointIP {
            wg.updateEndpointRoute(gateway: gateway)
            wg.applyDNS(store: dynamicStore)
            return
        }
        guard gateway != nil else { return } // no network yet: try again when one shows up
        guard Date() >= wgRetryAt else { return }
        guard let endpointIP else {
            wgError = "Looking up \(tunnel.endpointHost)…"
            refreshHosts(force: true)
            scheduleWireGuardRetry(after: 5)
            return
        }
        guard let keys = wgKeys.load()[id] else {
            wgError = "The private key of \(tunnel.name) is missing. Remove this VPN and add it again."
            return
        }
        do {
            try wg.up(tunnel, keys: keys, endpointIP: endpointIP, gateway: gateway, store: dynamicStore)
            wgError = nil
            wgFailures = 0
            Log.info("WireGuard \(tunnel.name) up on \(wg.interface ?? "?") to \(endpointIP):\(tunnel.endpointPort)")
            // Rebuild the lock rules so they include the new tunnel interface.
            queue.async { [weak self] in self?.evaluate("wireguard up") }
        } catch {
            wgFailures += 1
            wgError = error.localizedDescription
            Log.error("WireGuard \(tunnel.name) failed: \(error.localizedDescription)")
            scheduleWireGuardRetry(after: min(60, pow(2, Double(wgFailures))))
        }
    }

    private func scheduleWireGuardRetry(after seconds: TimeInterval) {
        wgRetryAt = Date().addingTimeInterval(seconds)
        queue.asyncAfter(deadline: .now() + seconds + 0.1) { [weak self] in self?.evaluate("wireguard retry") }
    }

    private func wgRuntime() -> WireGuardRuntime? {
        guard let id = config.wgActive else { return nil }
        if wg.isRunning, wg.tunnelID == id {
            let s = wg.stats()
            return WireGuardRuntime(tunnelID: id, interface: wg.interface, startedAt: wg.startedAt,
                                    lastHandshake: s?.handshake, rxBytes: s?.rx ?? 0, txBytes: s?.tx ?? 0, error: wgError)
        }
        return WireGuardRuntime(tunnelID: id, error: wgError)
    }

    /// Called on SIGTERM (update or uninstall): take the tunnel down cleanly.
    func shutdown() {
        queue.sync {
            if wg.isRunning || wg.tunnelID != nil { wg.down(store: dynamicStore) }
        }
    }

    // MARK: - VPN server host names

    /// Looks up host-name servers off the queue: every 30 s while one has no IP yet, every 5 min while
    /// locked (works thanks to the DNS lookup rule), otherwise every 10 min; `force` for right now.
    private func refreshHosts(force: Bool = false) {
        let hosts = config.serverHosts.filter(Net.isHostName)
        guard !hosts.isEmpty else { return }
        guard !hostRefreshRunning else {
            // Asked while one runs (e.g. a new server added): run again right after, don't drop it.
            if force { hostRefreshPending = true }
            return
        }
        let missing = hosts.contains { (config.hostIPs[$0] ?? []).isEmpty }
        let interval: TimeInterval = missing ? 30 : (appliedMode == .locked ? 300 : 600)
        guard force || Date().timeIntervalSince(lastHostRefresh) >= interval else { return }
        hostRefreshRunning = true
        lastHostRefresh = Date()
        let locked = appliedMode == .locked
        if locked { setDNSWindow(open: true) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var answers: [String: [String]] = [:]
            var problems: [String] = []
            for host in hosts {
                let r = DNS.lookup(host, fixedPortOnly: locked)
                if r.ips.isEmpty { problems.append("\(host): \(r.problem ?? "no answer")") } else { answers[host] = r.ips.sorted() }
            }
            self?.queue.async { self?.finishHostRefresh(answers, problems: problems, locked: locked) }
        }
    }

    /// Opens or closes lock mode's DNS lookup rule right now (only matters while locked).
    private func setDNSWindow(open: Bool) {
        guard dnsWindowOpen != open else { return }
        dnsWindowOpen = open
        if appliedMode == .locked { apply(.locked, links: currentLinks) }
    }

    private func finishHostRefresh(_ answers: [String: [String]], problems: [String], locked: Bool) {
        hostRefreshRunning = false
        setDNSWindow(open: false)
        let problem = problems.isEmpty ? nil : "\(locked ? "while locked: " : "")\(problems.joined(separator: "; "))"
        if problem != lastLookupProblem {
            if let problem { Log.error("Could not look up VPN server \(problem)") }
            else if lastLookupProblem != nil { Log.info("VPN server names look up fine again") }
            lastLookupProblem = problem
        }
        defer {
            if hostRefreshPending {
                hostRefreshPending = false
                refreshHosts(force: true)
            }
        }
        var changed = false
        for (host, ips) in answers where config.serverHosts.contains(host) && config.hostIPs[host] != ips {
            Log.info("VPN server \(host) is \(ips.joined(separator: ", "))")
            config.hostIPs[host] = ips
            changed = true
        }
        guard changed else { return }
        persist()
        syncPinnedNames()
        evaluate("server IP changed")
    }

    /// Feeds the local DNS answerer and keeps /etc/resolver in step with it.
    private func syncPinnedNames() {
        var pins: [String: [String]] = [:]
        for host in config.serverHosts where Net.isHostName(host) {
            if let ips = config.hostIPs[host], !ips.isEmpty { pins[host] = ips }
        }
        dnsServer.update(pins)
        ResolverFiles.sync(hosts: pins.keys.sorted())
    }

    private func persist() {
        do {
            try configStore.save(config)
        } catch {
            Log.error("Could not save config: \(error)")
        }
    }

    // MARK: - Commands from the app / CLI

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func handle(_ command: HelperCommand) throws -> GuardStatus {
        dispatchPrecondition(condition: .onQueue(queue))
        switch command {
        case .status:
            status.wg = wgRuntime()

        case .refresh:
            evaluate("refresh")

        case .trustCurrent(let rawName):
            evaluate("trust request")
            let links = status.links
            guard !links.isEmpty else { throw CommandError(message: "You are not connected to a network with a router.") }
            let candidates = links.filter { $0.trustedName == nil }
            guard !candidates.isEmpty else { throw CommandError(message: "This network is already trusted.") }
            guard candidates.allSatisfy({ $0.routerMAC != nil }) else {
                throw CommandError(message: "The router's hardware address is not known yet. Try again in a few seconds.")
            }
            // One entry per router, even if the Mac reaches it over Wi-Fi and a cable.
            for entry in TrustedNetwork.newEntries(name: Self.cleanName(rawName), candidates: candidates) {
                config.trusted.append(entry)
                Log.info("Trusted \(entry.name): router \(entry.routerIP ?? "?") \(entry.routerMAC)")
            }
            persist()
            evaluate("trusted")

        case .untrust(let id):
            guard let t = config.trusted.first(where: { $0.id == id }) else {
                throw CommandError(message: "That trusted network does not exist any more.")
            }
            config.trusted.removeAll { $0.id == id }
            Log.info("Removed trusted network \(t.name)")
            persist()
            evaluate("untrusted")

        case .rename(let id, let rawName):
            guard let i = config.trusted.firstIndex(where: { $0.id == id }) else {
                throw CommandError(message: "That trusted network does not exist any more.")
            }
            config.trusted[i].name = Self.cleanName(rawName)
            persist()
            evaluate("renamed")

        case .pause(let minutes):
            guard config.enabled else { throw CommandError(message: "Protection is off, so there is nothing to pause.") }
            guard (1...1440).contains(minutes) else { throw CommandError(message: "Pause must be 1 to 1440 minutes.") }
            config.pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            Log.info("Paused for \(minutes) min")
            persist()
            evaluate("paused")

        case .resume:
            config.pausedUntil = nil
            persist()
            evaluate("resumed")

        case .setEnabled(let on):
            config.enabled = on
            if !on { config.pausedUntil = nil }
            Log.info("Protection \(on ? "ON" : "OFF")")
            persist()
            evaluate(on ? "enabled" : "disabled")

        case .setVPNServers(let list):
            let cleaned = list.map(GuardConfig.normalizeServer).filter { !$0.isEmpty }
            if let bad = cleaned.first(where: { !Net.isIPv4($0) && !Net.isHostName($0) }) {
                throw CommandError(message: "\"\(bad)\" is not an IPv4 address or a host name.")
            }
            guard cleaned.count <= 16 else { throw CommandError(message: "Use 16 servers or fewer.") }
            config.vpnServers = cleaned.uniqued()
            // Keep looked-up IPs of servers that left the list: they are a cache (bug: switching VPN
            // while locked deleted the IP, and DNS was blocked, so the VPN could not connect).
            config.pruneHostCache()
            Log.info("VPN servers: \(config.vpnServers.joined(separator: ", "))")
            persist()
            syncPinnedNames()
            evaluate("servers changed")
            refreshHosts(force: true)

        case .lookUpServers:
            refreshHosts(force: true)

        case .wgAdd(let tunnel, let privateKey, let presharedKey):
            guard let ours = WireGuardKey.publicKey(fromPrivate: privateKey) else {
                throw CommandError(message: "The private key is not a WireGuard key.")
            }
            if let psk = presharedKey, !WireGuardKey.isValid(psk) {
                throw CommandError(message: "The pre-shared key is not a WireGuard key.")
            }
            var t = tunnel
            t.name = Self.cleanName(t.name, fallback: "WireGuard")
            t.publicKey = ours
            t.hasPresharedKey = presharedKey != nil
            if let problem = t.problems().first { throw CommandError(message: problem) }
            guard config.wireguard.count < 32 else { throw CommandError(message: "Use 32 WireGuard VPNs or fewer.") }
            guard !config.wireguard.contains(where: { $0.name.lowercased() == t.name.lowercased() }) else {
                throw CommandError(message: "A WireGuard VPN named \"\(t.name)\" already exists.")
            }
            if config.wireguard.contains(where: { $0.id == t.id }) { t.id = UUID() }
            var keys = wgKeys.load()
            keys[t.id] = WireGuardKeys(privateKey: privateKey, presharedKey: presharedKey)
            do { try wgKeys.save(keys) } catch {
                throw CommandError(message: "Could not save the key: \(error.localizedDescription)")
            }
            config.wireguard.append(t)
            Log.info("Added WireGuard VPN \(t.name) (server \(t.endpoint))")
            persist()
            syncPinnedNames()
            evaluate("wireguard added")
            refreshHosts(force: true)

        case .wgRemove(let id):
            guard let t = config.wireguard.first(where: { $0.id == id }) else {
                throw CommandError(message: "That WireGuard VPN does not exist any more.")
            }
            if config.wgActive == id { config.wgActive = nil }
            config.wireguard.removeAll { $0.id == id }
            config.pruneHostCache()
            var keys = wgKeys.load()
            keys[id] = nil
            try? wgKeys.save(keys)
            Log.info("Removed WireGuard VPN \(t.name)")
            persist()
            syncPinnedNames()
            evaluate("wireguard removed")

        case .wgConnect(let id):
            guard let t = config.wireguard.first(where: { $0.id == id }) else {
                throw CommandError(message: "That WireGuard VPN does not exist any more.")
            }
            config.wgActive = id
            wgFailures = 0
            wgRetryAt = .distantPast
            wgError = nil
            Log.info("WireGuard \(t.name): connect")
            persist()
            evaluate("wireguard connect")
            status.wg = wgRuntime()

        case .wgDisconnect:
            config.wgActive = nil
            persist()
            evaluate("wireguard disconnect")
        }
        return status
    }

    private static func cleanName(_ raw: String, fallback: String = "Trusted network") -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        return s.isEmpty ? fallback : String(s.prefix(64))
    }
}

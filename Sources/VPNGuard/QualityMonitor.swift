import AppKit
import Foundation
import Network
import SwiftUI
import VPNGuardCore

/// Where the Mac is and what its traffic goes through, for one quality check.
struct QualityContext: Equatable {
    /// The trusted network's name, else "iPhone hotspot" or the card's name.
    var network: String
    /// A VPN's name or `QualityVia.noVPN`. Nil: nothing can reach the internet now (locked, VPN down).
    var via: String?
    /// The VPN server's IPv4 address while a VPN is up (its ping outside the tunnel is "the road").
    var serverIP: String?
    /// The card macOS uses ("en0") and its name for people ("Wi-Fi").
    var card: String?
    var cardLabel: String
    var routerIP: String?
    /// The VPN in use or wanted here, also while it is down.
    var vpnName: String?
    /// Normal internet here (trusted, paused, protection off): a test without the VPN is allowed.
    var directAllowed: Bool
    var paused: Bool
    var trusted: Bool
}

enum QualityTab: String, CaseIterable, Identifiable {
    case monitor, compare, history, servers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: return "Monitor"
        case .compare: return "Compare"
        case .history: return "History"
        case .servers: return "Servers"
        }
    }

    var symbol: String {
        switch self {
        case .monitor: return "waveform.path.ecg"
        case .compare: return "chart.bar.fill"
        case .history: return "clock.fill"
        case .servers: return "server.rack"
        }
    }

    var color: Color {
        switch self {
        case .monitor: return Color(hex: 0x34A853)
        case .compare: return Color(hex: 0x0A84FF)
        case .history: return Color(hex: 0x5E5CE6)
        case .servers: return Color(hex: 0x636366)
        }
    }
}

/// Measures ping (in the background only if the user turned it on, otherwise while the window is
/// open), runs tests (one connection or several in turn), and keeps the results on this Mac.
@MainActor
final class QualityMonitor: ObservableObject {
    @Published private(set) var history = QualityHistory()
    @Published var tab: QualityTab = .monitor
    /// "Keep checking in the background": every 60 s. Off by default.
    @Published var backgroundOn: Bool {
        didSet {
            guard backgroundOn != oldValue else { return }
            UserDefaults.standard.set(backgroundOn, forKey: Self.backgroundKey)
            reschedule()
        }
    }
    @Published private(set) var windowOpen = false
    /// The test server for pings and speed (`TestServer.id`). Cloudflare by default.
    @Published var serverID: String {
        didSet {
            guard serverID != oldValue else { return }
            UserDefaults.standard.set(serverID, forKey: Self.serverKey)
            if windowOpen { tick() }
        }
    }
    /// Connect times measured on the Servers tab, by server id (nil: no answer).
    @Published private(set) var serverTimes: [String: Double?] = [:]
    /// Through what and when the servers were measured.
    @Published private(set) var serversMeasured: (via: String, at: Date)?
    @Published private(set) var measuringServers = false
    /// The test running now.
    @Published private(set) var run: TestRun?
    /// What the last test could not do ("Stopped after 1 of 3.").
    @Published private(set) var runNote: String?
    /// Compare tab: the connections picked (VPN ids and `noVPNID`) and Ping or Ping + speed.
    @Published var picked: Set<String> = []
    @Published var withSpeed = true
    /// Router pings of the last minutes, also while nothing else can go out.
    @Published private(set) var routerChecks: [(at: Date, ms: Double?)] = []

    var server: TestServer { TestServers.server(id: serverID) }
    var speedServer: TestServer { TestServers.speedServer(for: server) }

    struct TestRun: Equatable {
        enum Step: Equatable { case waiting, connecting, ping, speed, done, failed(String), skipped }
        struct Item: Equatable, Identifiable {
            var id: String
            var name: String
            var step: Step = .waiting
            var stepStarted: Date?
            var test: QualityTest?
        }
        var network: String
        var withSpeed: Bool
        var items: [Item]
        /// The VPN in use when it started (no switch needed for it).
        var startedWith: String?

        var current: Int? { items.firstIndex { [.connecting, .ping, .speed].contains($0.step) } }
        var doneCount: Int { items.filter { $0.step == .done || $0.step == .skipped || { if case .failed = $0.step { return true }; return false }($0) }.count }

        /// About how long the rest takes.
        func secondsLeft(now: Date = Date()) -> Int {
            var left = 0.0
            for it in items {
                let switching = it.name != startedWith
                let full = QualityMonitor.estimate(seconds: withSpeed, switching: switching)
                switch it.step {
                case .waiting: left += full
                case .connecting: left += full - min(QualityMonitor.connectSeconds, now.timeIntervalSince(it.stepStarted ?? now))
                case .ping:
                    left += QualityMonitor.pingSeconds - now.timeIntervalSince(it.stepStarted ?? now)
                        + (withSpeed ? QualityMonitor.fullSpeedSeconds : 0)
                case .speed: left += QualityMonitor.fullSpeedSeconds - now.timeIntervalSince(it.stepStarted ?? now)
                default: break
                }
            }
            return max(0, Int(left.rounded()))
        }
    }

    static let noVPNID = "novpn"
    static let backgroundKey = "qualityBackground"
    static let serverKey = "qualityPingServer"
    static let backgroundInterval: TimeInterval = 60
    static let windowInterval: TimeInterval = 2
    /// Download seconds of a speed test (the upload takes 6 more).
    nonisolated static let speedSeconds: Double = 8
    nonisolated static let fullSpeedSeconds: Double = 15
    nonisolated static let pingSeconds: Double = 9
    nonisolated static let connectSeconds: Double = 12
    /// A speed test uses up to about this much data on a fast line.
    nonisolated static let speedMegabytes = 350

    /// Seconds for one connection in a test.
    nonisolated static func estimate(seconds withSpeed: Bool, switching: Bool) -> Double {
        (switching ? connectSeconds : 0) + pingSeconds + (withSpeed ? fullSpeedSeconds : 0)
    }

    weak var model: AppModel?
    let isPreview: Bool
    private var timer: Timer?
    private var probing = false
    private var saveScheduled = false
    /// VPN servers that answered a ping at least once: one that never does ignores ICMP (no loss).
    private var answeringServers = Set<String>()
    private let path = NWPathMonitor()
    /// Phone hotspot or Low Data Mode: a speed test asks first.
    private(set) var costlyNetwork = false
    private var httpSpeed: HTTPSpeedTest?
    /// Host names of the test servers, looked up at most every 10 minutes.
    nonisolated private static let names = NameCache()
    private var cancelled = false
    private var unstable = UnstableTracker()
    /// Whether protection was paused / off when the test started: a change stops it.
    private var runStartedPaused: (paused: Bool, off: Bool)?

    init(preview: Bool) {
        isPreview = preview
        backgroundOn = preview ? false : UserDefaults.standard.bool(forKey: Self.backgroundKey)
        serverID = preview ? TestServers.defaultID : TestServers.server(id: UserDefaults.standard.string(forKey: Self.serverKey)).id
        guard !preview else { return }
        history = Self.load()
        history.prune(now: Date())
        path.pathUpdateHandler = { [weak self] p in
            let costly = p.isExpensive || p.isConstrained
            DispatchQueue.main.async { self?.costlyNetwork = costly }
        }
        path.start(queue: .global(qos: .utility))
        reschedule()
    }

    // MARK: - Window and schedule

    func windowOpened() {
        guard !windowOpen else { return }
        windowOpen = true
        reschedule()
        tick()
        if tab == .servers, serverTimes.isEmpty { measureServers() }
    }

    func windowClosed() {
        guard windowOpen else { return }
        windowOpen = false
        reschedule()
        save()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard !isPreview else { return }
        let interval: TimeInterval? = windowOpen ? Self.windowInterval : (backgroundOn ? Self.backgroundInterval : nil)
        guard let interval else {
            if let e = unstable.close() { history.events.append(e) }
            return
        }
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval / 5
        timer = t
    }

    /// One check: the test server the normal way, the VPN server outside the tunnel, and the router.
    /// The router answers even while the lock is on (the rules let pings to it out).
    func tick() {
        guard !isPreview, !probing, run == nil, let c = model?.qualityContext else { return }
        probing = true
        let via = c.via, server = c.serverIP, card = c.card, router = c.routerIP
        let target = self.server
        DispatchQueue.global(qos: .utility).async {
            let internet = via == nil ? nil : Self.ping(target)
            let road = server.flatMap { QualityProbe.ping($0, interface: card, tcpFallback: false) }
            let toRouter = router.flatMap { QualityProbe.ping($0, interface: card, timeout: 1, tcpFallback: false) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probing = false
                    // The place or the connection changed meanwhile: the answer belongs to neither.
                    guard let now = self.model?.qualityContext, now.network == c.network, now.via == via,
                          self.serverID == target.id else { return }
                    self.noteRouter(router == nil ? nil : toRouter)
                    if let via {
                        self.record(network: c.network, via: via, internet: internet, server: server, road: road,
                                    router: toRouter, target: target.id)
                    }
                }
            }
        }
    }

    private func noteRouter(_ ms: Double?) {
        let now = Date()
        routerChecks.append((now, ms))
        routerChecks.removeAll { now.timeIntervalSince($0.at) > 180 }
    }

    private func record(network: String, via: String, internet: Double?, server: String?, road: Double?,
                        router: Double?, target: String, watch: Bool = true) {
        if let server, road != nil { answeringServers.insert(server) }
        let tried = server.map { answeringServers.contains($0) } ?? false
        let now = Date()
        history.pings.append(PingSample(at: now, network: network, via: via, internet: internet,
                                        server: road, serverTried: tried, target: target, router: router))
        if watch {
            let recent = history.pings(network: network, via: via, since: now.addingTimeInterval(-180), target: target)
            if let e = unstable.update(network: network, via: via, stats: PingStats(recent.map(\.internet)), now: now) {
                history.events.append(e)
            }
        }
        scheduleSave()
    }

    // MARK: - Events from the app

    func note(_ event: VPNEvent) {
        guard !isPreview else { return }
        history.events.append(event)
        scheduleSave()
    }

    /// A VPN could not connect. Several tries in a row are one event.
    func noteFailure(vpn: String, network: String?, reason: String) {
        guard !isPreview else { return }
        let now = Date()
        if history.events.contains(where: { $0.kind == .failed && $0.vpn == vpn && $0.network == network
            && now.timeIntervalSince($0.at) < 600 }) { return }
        note(VPNEvent(at: now, kind: .failed, network: network, vpn: vpn, detail: reason))
    }

    /// VPN Guard went on with a backup VPN after `failed` did not connect.
    func noteBackup(failed: String, using: String) {
        guard !isPreview, let i = history.events.lastIndex(where: { $0.kind == .failed && $0.vpn == failed }),
              Date().timeIntervalSince(history.events[i].at) < 600 else { return }
        let detail = history.events[i].detail ?? ""
        guard !detail.contains("used ") else { return }
        history.events[i].detail = detail.isEmpty ? "Used \(using)" : "\(detail) · used \(using)"
        scheduleSave()
    }

    // MARK: - What the window shows

    /// The checks of the last `minutes` here, through what the Mac uses now.
    func recentStats(minutes: Double = 3) -> PingStats? {
        guard let c = model?.qualityContext, let via = c.via else { return nil }
        let xs = history.pings(network: c.network, via: via, since: Date().addingTimeInterval(-minutes * 60), target: serverID)
        return xs.isEmpty ? nil : PingStats(xs.map(\.internet))
    }

    /// Middle ping straight to the VPN server in the same time.
    func recentRoad(minutes: Double = 3) -> Double? {
        guard let c = model?.qualityContext, let via = c.via, via != QualityVia.noVPN else { return nil }
        let xs = history.pings(network: c.network, via: via, since: Date().addingTimeInterval(-minutes * 60), target: serverID)
        return PingStats.median(xs.filter(\.serverTried).compactMap(\.server))
    }

    /// The router pings of the last minutes.
    var routerStats: PingStats? {
        routerChecks.isEmpty ? nil : PingStats(routerChecks.map(\.ms))
    }

    /// Where the time goes now.
    func currentPath() -> QualityPath? {
        guard let c = model?.qualityContext else { return nil }
        return QualityPath(router: routerStats, server: recentRoad(), total: recentStats(),
                           viaVPN: c.via != nil && c.via != QualityVia.noVPN)
    }

    // MARK: - Tests (one connection, or several in turn)

    /// Connections in the test, in the order they run: the one in use first (no switch).
    func plannedItems() -> [TestRun.Item] {
        guard let m = model, let c = m.qualityContext else { return [] }
        let vpns = m.comparableVPNs.filter { picked.contains($0.id) }
        let current = vpns.filter { $0.id == m.activeVPNID && c.via == $0.name }
        var items = (current + vpns.filter { v in !current.contains { $0.id == v.id } }).map { TestRun.Item(id: $0.id, name: $0.name) }
        if picked.contains(Self.noVPNID), c.directAllowed {
            let item = TestRun.Item(id: Self.noVPNID, name: QualityVia.noVPN)
            if c.via == QualityVia.noVPN { items.insert(item, at: 0) } else { items.append(item) }
        }
        return items
    }

    func startRun() {
        guard !isPreview, run == nil, let m = model, let c = m.qualityContext else { return }
        let items = plannedItems()
        guard !items.isEmpty else { return }
        if withSpeed, costlyNetwork,
           !Dialogs.confirm(title: "Test speed on this network?",
                            message: "This looks like a phone hotspot or a network with Low Data Mode. A speed test uses up to \(Self.speedMegabytes) MB for each connection.",
                            button: "Test Speed") { return }
        run = TestRun(network: c.network, withSpeed: withSpeed, items: items, startedWith: c.via)
        runNote = nil
        cancelled = false
        runStartedPaused = (m.status?.reason == .paused, m.status?.reason == .disabled)
        let wasUp = m.vpnState == .connected
        Task { await perform(wasUp: wasUp) }
    }

    func stopRun() {
        cancelled = true
        httpSpeed?.cancel()
    }

    /// Same place, and protection not paused, resumed or turned off meanwhile?
    private func mayGoOn(_ network: String) -> Bool {
        guard !cancelled, let m = model, let c = m.qualityContext, c.network == network else { return false }
        let paused = m.status?.reason == .paused, off = m.status?.reason == .disabled
        return runStartedPaused.map { $0.paused == paused && $0.off == off } ?? true
    }

    private func setStep(_ i: Int, _ step: TestRun.Step) {
        run?.items[i].step = step
        run?.items[i].stepStarted = Date()
    }

    private func perform(wasUp: Bool) async {
        guard let started = run, let m = model else { return }
        var notes: [String] = []
        for i in started.items.indices {
            guard mayGoOn(started.network) else { break }
            let item = started.items[i]
            setStep(i, .connecting)
            let vpnWasUp = m.vpnState.isUp || m.vpnState == .connecting
            m.compareSwitch(to: item.id)
            if item.id == Self.noVPNID {
                // macOS needs a moment to take the VPN down and its routes away.
                if vpnWasUp { try? await Task.sleep(nanoseconds: 4_000_000_000) }
                guard mayGoOn(started.network) else { break }
                guard m.qualityContext?.via == QualityVia.noVPN else {
                    setStep(i, .failed("No normal internet here"))
                    notes.append("No VPN could not be tested.")
                    continue
                }
            } else {
                var waited = 0.0
                while m.vpnState != .connected, waited < 40, mayGoOn(started.network) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 0.5
                }
                guard mayGoOn(started.network) else { break }
                guard m.vpnState == .connected else {
                    setStep(i, .failed("Could not connect"))
                    notes.append("\(item.name) could not connect.")
                    continue
                }
                if waited > 0 { try? await Task.sleep(nanoseconds: 2_000_000_000) }   // let routes settle
            }
            setStep(i, .ping)
            let c = m.qualityContext
            let server = item.id == Self.noVPNID ? nil : m.serverIP(of: m.activeVPN)
            let card = c?.card, router = c?.routerIP
            let target = self.server
            var values: [Double?] = []
            for _ in 0..<10 {
                guard mayGoOn(started.network) else { break }
                let (internet, road, toRouter) = await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let a = Self.ping(target)
                        let b = server.flatMap { QualityProbe.ping($0, interface: card, tcpFallback: false) }
                        let r = router.flatMap { QualityProbe.ping($0, interface: card, timeout: 1, tcpFallback: false) }
                        cont.resume(returning: (a, b, r))
                    }
                }
                values.append(internet)
                record(network: started.network, via: item.name, internet: internet, server: server, road: road,
                       router: toRouter, target: target.id, watch: false)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            guard values.count == 10 else { break }
            var test = QualityTest(at: Date(), network: started.network, via: item.name, server: target.id, stats: PingStats(values))
            run?.items[i].test = test   // the ping numbers show while the speed test runs
            if started.withSpeed, mayGoOn(started.network) {
                setStep(i, .speed)
                if let r = await speed() {
                    test.downMbps = r.down
                    test.upMbps = r.up
                    test.speedServer = r.server
                    test.megabytes = r.megabytes
                } else if mayGoOn(started.network) {
                    notes.append("The speed test of \(item.name) did not finish.")
                }
            }
            // Stopped during the speed test: no half result.
            if started.withSpeed, test.downMbps == nil, !mayGoOn(started.network) { break }
            history.tests.append(test)
            run?.items[i].test = test
            setStep(i, .done)
        }
        let done = run?.items.filter { $0.step == .done }.count ?? 0
        if let items = run?.items, done + items.filter({ if case .failed = $0.step { return true }; return false }).count < items.count {
            notes.insert(cancelled ? "Stopped after \(done) of \(items.count)." : "The test stopped after \(done) of \(items.count): the network or protection changed.", at: 0)
        }
        m.compareSwitch(to: nil)
        if !wasUp { m.stopVPNAfterCompare() }
        runNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        run = nil
        save()
    }

    /// Download (and upload) against the test server's files, or Cloudflare's.
    private func speed() async -> (down: Double, up: Double?, megabytes: Double, server: String)? {
        let s = speedServer
        guard let down = s.downloadURL.flatMap(URL.init(string:)) else { return nil }
        let test = HTTPSpeedTest()
        httpSpeed = test
        defer { httpSpeed = nil }
        let r = await test.run(download: down, upload: s.uploadURL.flatMap(URL.init(string:)), seconds: Self.speedSeconds)
        guard r.down > 0 else { return nil }
        return (r.down, s.uploadURL == nil || r.up <= 0 ? nil : r.up, r.megabytes, s.id)
    }

    // MARK: - Test servers

    /// One ping to a test server: Cloudflare's 1.1.1.1 (ICMP, else port 443), the others by the time a
    /// connection on port 443 takes. Blocking.
    nonisolated static func ping(_ s: TestServer) -> Double? {
        if s.id == TestServers.defaultID { return QualityProbe.ping(TestServers.cloudflarePingAddress) }
        guard let ip = names.ip(for: s.host) else { return nil }
        return QualityProbe.tcp(ip, port: 443, interface: nil, timeout: 2)
    }

    /// Measures every test server (port 443, best of two). Takes a few seconds.
    func measureServers() {
        guard !isPreview, !measuringServers, let via = model?.qualityContext?.via else { return }
        measuringServers = true
        let servers = TestServers.all
        DispatchQueue.global(qos: .userInitiated).async {
            var times = [String: Double?]()
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: servers.count) { i in
                let s = servers[i]
                let host = s.id == TestServers.defaultID ? TestServers.cloudflarePingAddress : s.host
                var best: Double?
                if let ip = Net.isIPv4(host) ? host : Self.names.ip(for: host) {
                    for _ in 0..<2 {
                        if let ms = QualityProbe.tcp(ip, port: 443, interface: nil, timeout: 2) { best = min(best ?? ms, ms) }
                    }
                }
                lock.withLock { times[s.id] = best }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.serverTimes = times
                    self?.serversMeasured = (via, Date())
                    self?.measuringServers = false
                }
            }
        }
    }

    // MARK: - History

    func csv(network: String?, since: Date) -> String {
        QualityCSV.make(tests: history.tests(network: network, since: since),
                        events: history.eventLog(network: network, since: since))
    }

    func clearHistory() {
        history = QualityHistory()
        unstable = UnstableTracker()
        runNote = nil
        save(now: true)
    }

    // MARK: - Saving

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VPN Guard", isDirectory: true).appendingPathComponent("quality.json")
    }

    private static func load() -> QualityHistory {
        guard let data = try? Data(contentsOf: fileURL),
              let h = try? JSONDecoder().decode(QualityHistory.self, from: data) else { return QualityHistory() }
        return h
    }

    /// Written at most every 5 minutes (and when the window closes or a test ends).
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    func save(now: Bool = false) {
        guard !isPreview else { return }
        saveScheduled = false
        history.prune(now: Date())
        let snapshot = history
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let url = Self.fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Previews

    func previewRun(_ r: TestRun?) { run = r }
    func previewServerTimes(_ t: [String: Double?], via: String) {
        serverTimes = t
        serversMeasured = (via, Date())
    }
    func previewHistory(_ h: QualityHistory) { history = h }
    func previewRouter(_ values: [Double?]) {
        let now = Date()
        routerChecks = values.enumerated().map { k, ms in (now.addingTimeInterval(Double(k - values.count) * 2), ms) }
    }
}

/// Test server host names -> IPv4, looked up again after 10 minutes. Thread safe.
final class NameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (ip: String, at: Date)] = [:]

    func ip(for host: String) -> String? {
        lock.lock()
        if let e = entries[host], Date().timeIntervalSince(e.at) < 600 { lock.unlock(); return e.ip }
        lock.unlock()
        guard let ip = Net.resolveIPv4(host).first(where: Net.isIPv4) else { return nil }
        lock.lock(); entries[host] = (ip, Date()); lock.unlock()
        return ip
    }
}

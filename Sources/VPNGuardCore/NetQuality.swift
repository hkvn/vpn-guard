import Foundation

// Network quality: ping, jitter, loss, speed, the path, and how stable the VPN is. Pure logic, tested.
// The app measures (QualityMonitor); this file turns measurements into numbers, grades and words.

/// One check: a ping to the test server the normal way (through the VPN when it is up), one straight
/// to the VPN server outside the tunnel (the "road" under the VPN), and one to the router.
public struct PingSample: Codable, Equatable, Sendable {
    public var at: Date
    /// Where: the trusted network's name, or the card's name ("Wi-Fi", "iPhone hotspot").
    public var network: String
    /// Through what: a VPN's name, or `QualityVia.noVPN`.
    public var via: String
    /// Milliseconds to the test server. Nil: no answer (lost).
    public var internet: Double?
    /// Milliseconds to the VPN server outside the tunnel. Nil: no answer, or not tried (`serverTried`).
    public var server: Double?
    public var serverTried: Bool
    /// The test server pinged (`TestServer.id`). Nil: Cloudflare, from before servers could be chosen.
    public var target: String?
    /// Milliseconds to the router. Nil: no answer or not tried.
    public var router: Double?
    public var targetID: String { target ?? TestServers.defaultID }

    public init(at: Date, network: String, via: String, internet: Double?, server: Double? = nil, serverTried: Bool = false,
                target: String? = nil, router: Double? = nil) {
        self.at = at
        self.network = network
        self.via = via
        self.internet = internet
        self.server = server
        self.serverTried = serverTried
        self.target = target
        self.router = router
    }
}

public enum QualityVia {
    public static let noVPN = "No VPN"
}

public struct PingStats: Equatable, Sendable {
    /// Checks counted (answered or lost).
    public var count: Int
    /// Middle ping of the answered checks.
    public var median: Double?
    /// How much the ping jumps: the average difference between one answer and the next.
    public var jitter: Double?
    /// Share of checks without an answer, 0...1.
    public var loss: Double

    /// `values`: one per check, nil = lost.
    public init(_ values: [Double?]) {
        count = values.count
        let answered = values.compactMap { $0 }
        loss = values.isEmpty ? 0 : Double(values.count - answered.count) / Double(values.count)
        median = PingStats.median(answered)
        if answered.count >= 2 {
            let steps = zip(answered, answered.dropFirst()).map { abs($1 - $0) }
            jitter = steps.reduce(0, +) / Double(steps.count)
        } else {
            jitter = nil
        }
    }

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

public enum QualityGrade: String, Equatable, Sendable {
    case good, fair, poor, unknown

    /// Video calls are the yardstick: they break up first.
    public static func of(_ s: PingStats) -> QualityGrade {
        guard s.count >= 3, let median = s.median else { return s.count >= 3 && s.loss >= 1 ? .poor : .unknown }
        let jitter = s.jitter ?? 0
        if s.loss >= 0.05 || median >= 150 || jitter >= 30 { return .poor }
        if QualityLimits.lossIsHigh(s.loss) || QualityLimits.pingIsHigh(median) || QualityLimits.jitterIsHigh(jitter) {
            return .fair
        }
        return .good
    }

    public var title: String {
        switch self {
        case .good: return "Stable"
        case .fair: return "A bit unstable"
        case .poor: return "Unstable"
        case .unknown: return "Measuring"
        }
    }

    /// One sentence for the status card.
    public var advice: String {
        switch self {
        case .good: return "Good for video calls."
        case .fair: return "Fine for browsing, calls may stutter."
        case .poor: return "Calls will break up, pages may stall."
        case .unknown: return "The first checks come in a few seconds."
        }
    }
}

/// From where a number is worth a second look (shown in orange).
public enum QualityLimits {
    public static func pingIsHigh(_ ms: Double) -> Bool { ms >= 80 }
    public static func jitterIsHigh(_ ms: Double) -> Bool { ms >= 15 }
    public static func lossIsHigh(_ share: Double) -> Bool { share >= 0.01 }
}

/// One test of one connection on one network: ping, and speed if it was asked for.
public struct QualityTest: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    public var network: String
    /// A VPN's name or `QualityVia.noVPN`.
    public var via: String
    /// The test server pinged (`TestServer.id`).
    public var server: String
    public var ping: Double?
    public var jitter: Double?
    /// 0...1. Nil: no ping test.
    public var loss: Double?
    public var downMbps: Double?
    /// Nil: no upload test (the server has none, or ping only).
    public var upMbps: Double?
    /// Where the speed test ran (`TestServer.id`). Nil: ping only.
    public var speedServer: String?
    /// About how much data the speed test used.
    public var megabytes: Double?

    public init(id: UUID = UUID(), at: Date, network: String, via: String, server: String, ping: Double? = nil,
                jitter: Double? = nil, loss: Double? = nil, downMbps: Double? = nil, upMbps: Double? = nil,
                speedServer: String? = nil, megabytes: Double? = nil) {
        self.id = id
        self.at = at
        self.network = network
        self.via = via
        self.server = server
        self.ping = ping
        self.jitter = jitter
        self.loss = loss
        self.downMbps = downMbps
        self.upMbps = upMbps
        self.speedServer = speedServer
        self.megabytes = megabytes
    }

    public init(at: Date, network: String, via: String, server: String, stats: PingStats?,
                downMbps: Double? = nil, upMbps: Double? = nil, speedServer: String? = nil, megabytes: Double? = nil) {
        self.init(at: at, network: network, via: via, server: server, ping: stats?.median, jitter: stats?.jitter,
                  loss: stats.map(\.loss), downMbps: downMbps, upMbps: upMbps, speedServer: speedServer, megabytes: megabytes)
    }
}

/// Background pings older than 7 days, one number per day.
public struct PingDay: Codable, Equatable, Sendable {
    /// The start of the day.
    public var day: Date
    public var network: String
    public var via: String
    public var target: String
    public var median: Double?
    public var jitter: Double?
    public var loss: Double
    public var count: Int

    public init(day: Date, network: String, via: String, target: String, median: Double?, jitter: Double?, loss: Double, count: Int) {
        self.day = day
        self.network = network
        self.via = via
        self.target = target
        self.median = median
        self.jitter = jitter
        self.loss = loss
        self.count = count
    }
}

/// What happened to the VPN and the network: for "VPN today" and the Events log.
public struct VPNEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// The VPN is needed here (untrusted network, protection on) / no longer needed.
        case needed, notNeeded
        /// Connected; `seconds` = how long connecting took, when known.
        case up
        /// Went down by itself (not stopped by the user or VPN Guard).
        case dropped
        /// Stopped on purpose.
        case stopped
        /// Could not connect; `detail` = the reason (and the backup VPN used, if any).
        case failed
        /// The connection was unstable for `seconds`; `detail` = the worst numbers.
        case unstable
    }
    public var at: Date
    public var kind: Kind
    public var seconds: Double?
    public var network: String?
    /// The VPN's name (for `unstable`: the connection, maybe `QualityVia.noVPN`).
    public var vpn: String?
    public var detail: String?

    public init(at: Date, kind: Kind, seconds: Double? = nil, network: String? = nil, vpn: String? = nil, detail: String? = nil) {
        self.at = at
        self.kind = kind
        self.seconds = seconds
        self.network = network
        self.vpn = vpn
        self.detail = detail
    }
}

public struct Stability: Equatable, Sendable {
    /// Share of the time the VPN was needed in which it was up, 0...1. Nil: not needed since `from`.
    public var protectedShare: Double?
    public var drops: Int
    public var longestUp: TimeInterval?
    public var averageConnect: TimeInterval?
    /// Seconds from the last drop to the next "up".
    public var lastRecovery: TimeInterval?

    /// Replays the events from `from` to `now`. State before `from` comes from the last events before it.
    public init(events: [VPNEvent], from: Date, now: Date) {
        let sorted = events.sorted { $0.at < $1.at }
        var needed = false, up = false
        for e in sorted where e.at < from { Self.apply(e, needed: &needed, up: &up) }
        var t = from
        var neededTime: TimeInterval = 0, protectedTime: TimeInterval = 0
        var upSince: Date? = up ? from : nil
        var longest: TimeInterval = 0
        var droppedAt: Date?
        var connects: [Double] = []
        drops = 0
        lastRecovery = nil
        func advance(to date: Date) {
            let span = max(0, date.timeIntervalSince(t))
            if needed { neededTime += span; if up { protectedTime += span } }
            t = date
        }
        for e in sorted where e.at >= from && e.at <= now {
            advance(to: e.at)
            switch e.kind {
            case .up:
                if !up { upSince = e.at }
                if let s = e.seconds { connects.append(s) }
                if let d = droppedAt { lastRecovery = e.at.timeIntervalSince(d); droppedAt = nil }
            case .dropped:
                drops += 1
                droppedAt = e.at
                fallthrough
            case .stopped:
                if up, let s = upSince { longest = max(longest, e.at.timeIntervalSince(s)) }
                upSince = nil
            case .needed, .notNeeded, .failed, .unstable:
                break
            }
            Self.apply(e, needed: &needed, up: &up)
        }
        advance(to: now)
        if up, let s = upSince { longest = max(longest, now.timeIntervalSince(s)) }
        protectedShare = neededTime > 0 ? protectedTime / neededTime : nil
        longestUp = longest > 0 ? longest : nil
        averageConnect = connects.isEmpty ? nil : connects.reduce(0, +) / Double(connects.count)
    }

    private static func apply(_ e: VPNEvent, needed: inout Bool, up: inout Bool) {
        switch e.kind {
        case .needed: needed = true
        case .notNeeded: needed = false
        case .up: up = true
        case .dropped, .stopped: up = false
        case .failed, .unstable: break
        }
    }
}

/// One line of the Events log.
public struct EventLine: Equatable, Sendable {
    public enum Tone: Sendable { case orange, red }
    public var at: Date
    public var network: String?
    public var title: String
    public var detail: String
    public var tone: Tone
}

/// One point of the History charts: one connection in one day (or week).
public struct TrendPoint: Equatable, Sendable {
    public var via: String
    /// The start of the day or week.
    public var at: Date
    public var ping: Double?
    public var down: Double?
    public var up: Double?
}

/// Everything measured, kept on this Mac. Tests and events 1 year; background pings 7 days, then one
/// number per day (also 1 year).
public struct QualityHistory: Codable, Equatable, Sendable {
    public var pings: [PingSample] = []
    public var days: [PingDay] = []
    public var tests: [QualityTest] = []
    public var events: [VPNEvent] = []

    public static let pingDays = 7
    public static let keepDays = 366

    public init() {}

    private enum CodingKeys: String, CodingKey { case pings, days, tests, events, speeds }

    /// A speed test from development builds of 1.3.0 (kept apart from pings then).
    private struct OldSpeed: Decodable {
        var at: Date, network: String, via: String, downMbps: Double, upMbps: Double, server: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pings = try c.decodeIfPresent([PingSample].self, forKey: .pings) ?? []
        days = try c.decodeIfPresent([PingDay].self, forKey: .days) ?? []
        tests = try c.decodeIfPresent([QualityTest].self, forKey: .tests) ?? []
        events = try c.decodeIfPresent([VPNEvent].self, forKey: .events) ?? []
        let old = (try? c.decodeIfPresent([OldSpeed].self, forKey: .speeds)) ?? nil
        tests += (old ?? []).map { s in
            QualityTest(at: s.at, network: s.network, via: s.via, server: TestServers.defaultID, downMbps: s.downMbps,
                        upMbps: s.upMbps > 0 ? s.upMbps : nil, speedServer: s.server ?? "apple")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pings, forKey: .pings)
        try c.encode(days, forKey: .days)
        try c.encode(tests, forKey: .tests)
        try c.encode(events, forKey: .events)
    }

    public var isEmpty: Bool { pings.isEmpty && days.isEmpty && tests.isEmpty && events.isEmpty }

    /// Pings of whole days older than 7 days become one number per day; anything older than a year goes.
    public mutating func prune(now: Date, calendar: Calendar = .current) {
        let pingCut = calendar.startOfDay(for: now.addingTimeInterval(-Double(Self.pingDays) * 86_400))
        let old = pings.filter { $0.at < pingCut }
        if !old.isEmpty {
            for day in Self.rollUp(old, calendar: calendar) {
                if let i = days.firstIndex(where: { $0.day == day.day && $0.network == day.network && $0.via == day.via
                    && $0.target == day.target }) {
                    days[i] = Self.merge(days[i], day)
                } else {
                    days.append(day)
                }
            }
            pings.removeAll { $0.at < pingCut }
        }
        let cut = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        days.removeAll { $0.day < cut }
        tests.removeAll { $0.at < cut }
        events.removeAll { $0.at < cut }
    }

    static func rollUp(_ samples: [PingSample], calendar: Calendar) -> [PingDay] {
        struct Key: Hashable { var day: Date, network: String, via: String, target: String }
        let groups = Dictionary(grouping: samples) {
            Key(day: calendar.startOfDay(for: $0.at), network: $0.network, via: $0.via, target: $0.targetID)
        }
        return groups.map { key, xs in
            let s = PingStats(xs.sorted { $0.at < $1.at }.map(\.internet))
            return PingDay(day: key.day, network: key.network, via: key.via, target: key.target, median: s.median,
                           jitter: s.jitter, loss: s.loss, count: s.count)
        }
        .sorted { $0.day < $1.day }
    }

    /// Two parts of one day (only if pings came in after the day was rolled up): weighted by count.
    static func merge(_ a: PingDay, _ b: PingDay) -> PingDay {
        let n = Double(a.count + b.count)
        func mix(_ x: Double?, _ y: Double?) -> Double? {
            switch (x, y) {
            case let (x?, y?): return (x * Double(a.count) + y * Double(b.count)) / n
            default: return x ?? y
            }
        }
        var m = a
        m.median = mix(a.median, b.median)
        m.jitter = mix(a.jitter, b.jitter)
        m.loss = (a.loss * Double(a.count) + b.loss * Double(b.count)) / n
        m.count = a.count + b.count
        return m
    }

    /// Every network seen, the most recently used first.
    public var networks: [String] {
        var last: [String: Date] = [:]
        func see(_ n: String?, _ at: Date) { if let n { last[n] = max(last[n] ?? .distantPast, at) } }
        pings.forEach { see($0.network, $0.at) }
        days.forEach { see($0.network, $0.day) }
        tests.forEach { see($0.network, $0.at) }
        events.forEach { see($0.network, $0.at) }
        return last.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// `target`: only pings to this test server (nil: any).
    public func pings(network: String, via: String? = nil, since: Date, target: String? = nil) -> [PingSample] {
        pings.filter { $0.network == network && $0.at >= since && (via == nil || $0.via == via)
            && (target == nil || $0.targetID == target) }
    }

    /// Tests since `since` (nil network: all networks), the newest first.
    public func tests(network: String?, since: Date) -> [QualityTest] {
        tests.filter { $0.at >= since && (network == nil || $0.network == network) }.sorted { $0.at > $1.at }
    }

    /// The last test of each connection on this network with this test server, by connection.
    public func latestTests(network: String, server: String) -> [String: QualityTest] {
        var out: [String: QualityTest] = [:]
        for t in tests where t.network == network && t.server == server {
            if let have = out[t.via], have.at >= t.at { continue }
            out[t.via] = t
        }
        return out
    }

    /// Medians per time slot for the live chart: `count` slots from `from` to `to`. Nil = no answer in it.
    public static func buckets(_ samples: [PingSample], value: (PingSample) -> Double??, from: Date, to: Date,
                               count: Int) -> [(at: Date, ms: Double?, lost: Bool)] {
        guard count > 0, to > from else { return [] }
        let width = to.timeIntervalSince(from) / Double(count)
        var slots = [[Double?]](repeating: [], count: count)
        for s in samples where s.at >= from && s.at < to {
            guard let v = value(s) else { continue }   // not measured
            let i = min(count - 1, Int(s.at.timeIntervalSince(from) / width))
            slots[i].append(v)
        }
        return slots.enumerated().compactMap { i, vs in
            guard !vs.isEmpty else { return nil }
            let answered = vs.compactMap { $0 }
            return (from.addingTimeInterval(width * (Double(i) + 0.5)), PingStats.median(answered), answered.count < vs.count)
        }
    }

    /// The History charts: per connection and day (or week), the middle ping of the tests and the
    /// background checks, and the middle download and upload of the tests. Only this test server.
    public func trend(network: String?, target: String, from: Date, to: Date, unit: Calendar.Component,
                      calendar: Calendar = .current) -> [TrendPoint] {
        struct Key: Hashable { var via: String, at: Date }
        struct Values { var ping: [Double] = [], down: [Double] = [], up: [Double] = [] }
        var slots: [Key: Values] = [:]
        func start(_ d: Date) -> Date { calendar.dateInterval(of: unit, for: d)?.start ?? calendar.startOfDay(for: d) }
        func fits(_ n: String, _ at: Date) -> Bool { at >= from && at <= to && (network == nil || n == network) }
        for t in tests where t.server == target && fits(t.network, t.at) {
            let k = Key(via: t.via, at: start(t.at))
            if let p = t.ping { slots[k, default: Values()].ping.append(p) }
            if let d = t.downMbps { slots[k, default: Values()].down.append(d) }
            if let u = t.upMbps { slots[k, default: Values()].up.append(u) }
        }
        for p in pings where p.targetID == target && fits(p.network, p.at) {
            if let ms = p.internet { slots[Key(via: p.via, at: start(p.at)), default: Values()].ping.append(ms) }
        }
        for d in days where d.target == target && fits(d.network, d.day) {
            if let ms = d.median { slots[Key(via: d.via, at: start(d.day)), default: Values()].ping.append(ms) }
        }
        return slots.map { k, v in
            TrendPoint(via: k.via, at: k.at, ping: PingStats.median(v.ping), down: PingStats.median(v.down),
                       up: PingStats.median(v.up))
        }
        .sorted { $0.at != $1.at ? $0.at < $1.at : $0.via < $1.via }
    }

    /// The Events log since `since` (nil network: all), the newest first: drops, failed connections,
    /// unstable times.
    public func eventLog(network: String?, since: Date) -> [EventLine] {
        let sorted = events.sorted { $0.at < $1.at }
        var lines: [EventLine] = []
        for (i, e) in sorted.enumerated() where e.at >= since && (network == nil || e.network == network) {
            let vpn = e.vpn ?? "The VPN"
            switch e.kind {
            case .dropped:
                let back = sorted[(i + 1)...].first { $0.kind == .up || $0.kind == .dropped || $0.kind == .stopped }
                var detail = ""
                if let back, back.kind == .up {
                    detail = "Back in \(QualityFormat.duration(back.at.timeIntervalSince(e.at)))"
                } else if back == nil || back?.kind == .stopped {
                    detail = "Did not come back by itself"
                }
                lines.append(EventLine(at: e.at, network: e.network, title: "\(vpn) dropped", detail: detail, tone: .orange))
            case .failed:
                lines.append(EventLine(at: e.at, network: e.network, title: "\(vpn) could not connect",
                                       detail: e.detail ?? "", tone: .red))
            case .unstable:
                let how = e.seconds.map { " for \(QualityFormat.duration($0))" } ?? ""
                let through = e.vpn.map { $0 == QualityVia.noVPN ? " (no VPN)" : " (\($0))" } ?? ""
                lines.append(EventLine(at: e.at, network: e.network, title: "Unstable\(how)\(through)",
                                       detail: e.detail ?? "", tone: .orange))
            case .needed, .notNeeded, .up, .stopped:
                break
            }
        }
        return lines.reversed()
    }
}

/// Ends of the path: where the time goes, and which part is slow.
public struct QualityPath: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        /// This Mac to the router (the Wi-Fi or cable).
        case local
        /// The router to the VPN server.
        case road
        /// The VPN server (or, without VPN, the router) to the test server.
        case internet
    }
    public var local: Double?
    public var road: Double?
    public var internet: Double?
    /// Nil: nothing slow, or not enough numbers.
    public var slow: Part?
    /// The time to the router jumps a lot.
    public var localJumps: Bool

    /// Local Wi-Fi or cable should answer in a few ms.
    public static let slowLocal: Double = 30

    /// `router`, `total`: the checks of the last minutes. `server`: the middle ping to the VPN server
    /// outside the tunnel (nil without a VPN or when it does not answer).
    public init(router: PingStats?, server: Double?, total: PingStats?, viaVPN: Bool) {
        local = router?.median
        localJumps = (router?.jitter).map(QualityLimits.jitterIsHigh) ?? false
        let base = local ?? 0
        if viaVPN {
            road = server.map { max(1, $0 - base) }
            internet = server.flatMap { s in total?.median.map { max(1, $0 - s) } }
        } else {
            road = nil
            internet = total?.median.map { max(1, $0 - base) }
        }
        if let l = local, l >= Self.slowLocal || localJumps {
            slow = .local
        } else if let total, [.fair, .poor].contains(QualityGrade.of(total)) {
            switch (road, internet) {
            case let (r?, i?): slow = r >= i ? .road : .internet
            case (_?, nil): slow = .road
            case (nil, _?): slow = .internet
            default: slow = nil
            }
        } else {
            slow = nil
        }
    }
}

/// Which connection did best in a comparison, in one sentence.
public struct CompareVerdict: Equatable, Sendable {
    public var best: String
    /// What it is compared with: the connection in use, else the runner-up.
    public var other: String?
    public var lessPing: Double?
    public var moreDown: Double?
    /// The best one is the one in use already.
    public var bestIsCurrent: Bool

    /// `tests`: the last test of each connection here. Only VPNs can be "used", so No VPN is left out.
    /// With speed for all: the most download (among those without loss); else the lowest ping.
    public static func decide(_ tests: [QualityTest], current: String?) -> CompareVerdict? {
        let vpns = tests.filter { $0.via != QualityVia.noVPN && $0.ping != nil }
        guard vpns.count >= 2 else { return nil }
        let healthy = vpns.filter { !QualityLimits.lossIsHigh($0.loss ?? 0) }
        let pool = healthy.isEmpty ? vpns : healthy
        let bySpeed = pool.allSatisfy { $0.downMbps != nil }
        func better(_ a: QualityTest, _ b: QualityTest) -> Bool {
            if bySpeed, let x = a.downMbps, let y = b.downMbps, abs(x - y) >= 0.05 { return x > y }
            return (a.ping ?? .infinity) < (b.ping ?? .infinity)
        }
        let ranked = pool.sorted(by: better) + vpns.filter { v in !pool.contains { $0.id == v.id } }
        let best = ranked[0]
        let other = current != best.via ? (vpns.first { $0.via == current } ?? ranked[1]) : ranked[1]
        var v = CompareVerdict(best: best.via, other: other.via, lessPing: nil, moreDown: nil, bestIsCurrent: best.via == current)
        if let a = best.ping, let b = other.ping, b - a >= 1 { v.lessPing = b - a }
        if let a = best.downMbps, let b = other.downMbps, a - b >= 1 { v.moreDown = a - b }
        return v
    }

    /// "Home is the best here." and "9 ms less ping and 13 Mbps more download than Office VPN."
    public var headline: String {
        bestIsCurrent ? "\(best) is the best here, and you use it." : "\(best) is the best here."
    }

    public var detail: String {
        var parts: [String] = []
        if let p = lessPing { parts.append("\(Int(p.rounded())) ms less ping") }
        if let d = moreDown { parts.append("\(Int(d.rounded())) Mbps more download") }
        guard !parts.isEmpty, let other else { return "" }
        return parts.joined(separator: " and ") + " than \(other)."
    }
}

/// Notices unstable times while checks run: poor for a while, then calm again for 5 minutes.
public struct UnstableTracker: Sendable {
    /// Shorter unstable times are not logged.
    public static let minimum: TimeInterval = 5 * 60
    /// Calm for this long: the unstable time has ended.
    public static let calm: TimeInterval = 5 * 60
    /// No checks for this long (window closed, background off): the unstable time ends at the last bad one.
    public static let gap: TimeInterval = 10 * 60

    private var network = ""
    private var via = ""
    private var start: Date?
    private var lastPoor: Date?
    private var lastSeen: Date?
    private var worstPing: Double = 0
    private var worstLoss: Double = 0

    public init() {}

    public var isUnstable: Bool { start != nil }

    /// `stats`: the checks of the last few minutes on `network` through `via`. Returns an event when an
    /// unstable time ends (on calm, on a gap in the checks, or when the place or connection changes).
    public mutating func update(network: String, via: String, stats: PingStats, now: Date) -> VPNEvent? {
        var ended: VPNEvent?
        let gap = lastSeen.map { now.timeIntervalSince($0) > Self.gap } ?? false
        if network != self.network || via != self.via || gap {
            ended = close()
            self.network = network
            self.via = via
        }
        lastSeen = now
        if QualityGrade.of(stats) == .poor {
            if start == nil {
                start = now
                worstPing = 0
                worstLoss = 0
            }
            lastPoor = now
            if let m = stats.median { worstPing = max(worstPing, m) }
            worstLoss = max(worstLoss, stats.loss)
        } else if start != nil, let last = lastPoor, now.timeIntervalSince(last) >= Self.calm {
            ended = close() ?? ended
        }
        return ended
    }

    /// Ends the unstable time now. Returns its event if it was long enough.
    public mutating func close() -> VPNEvent? {
        defer { start = nil; lastPoor = nil }
        guard let s = start, let e = lastPoor, e.timeIntervalSince(s) >= Self.minimum else { return nil }
        var parts: [String] = []
        if worstPing > 0 { parts.append("Up to \(Int(worstPing.rounded())) ms ping") }
        if QualityLimits.lossIsHigh(worstLoss) { parts.append("\(Int((worstLoss * 100).rounded())) % loss") }
        return VPNEvent(at: s, kind: .unstable, seconds: e.timeIntervalSince(s), network: network, vpn: via,
                        detail: parts.joined(separator: " · "))
    }
}

public enum QualityFormat {
    /// "6 s", "4 min", "3 h 12 min", "2 days".
    public static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        if m < 48 * 60 { return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min" }
        return "\(m / 1440) days"
    }

    /// "38 ms", or "–".
    public static func ms(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) ms" } ?? "–" }

    /// "48.2", "1 230", or "–" (Mbps without the unit).
    public static func mbps(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v >= 100 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
    }

    /// "0 %", "3 %", or "–".
    public static func percent(_ share: Double?) -> String {
        share.map { "\(Int(($0 * 100).rounded())) %" } ?? "–"
    }
}

/// History as a spreadsheet: tests and events in one table.
public enum QualityCSV {
    public static let header = "Type,Time,Network,Connection,Test server,Ping (ms),Jitter (ms),Loss (%),Download (Mbps),Upload (Mbps),What happened,Details"

    public static func make(tests: [QualityTest], events: [EventLine], timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func n(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        var rows: [(Date, [String])] = []
        for t in tests {
            rows.append((t.at, ["Test", f.string(from: t.at), t.network, t.via, TestServers.server(id: t.server).shortTitle,
                                n(t.ping, 0), n(t.jitter, 0), n(t.loss.map { $0 * 100 }, 0), n(t.downMbps), n(t.upMbps), "", ""]))
        }
        for e in events {
            rows.append((e.at, ["Event", f.string(from: e.at), e.network ?? "", "", "", "", "", "", "", "", e.title, e.detail]))
        }
        let lines = rows.sorted { $0.0 > $1.0 }.map { $0.1.map(field).joined(separator: ",") }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }

    /// Quotes a field when it needs it. A leading = + - @ is made harmless (spreadsheet formulas).
    static func field(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@".contains(first), Double(v) == nil { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

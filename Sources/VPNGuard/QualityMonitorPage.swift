import Charts
import SwiftUI
import VPNGuardCore

/// Monitor: is my connection good right now, and where is the time lost?
struct QualityMonitorPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor

    var body: some View {
        let c = model.qualityContext
        let stats = c?.via == nil ? nil : quality.recentStats()
        let path = quality.currentPath()
        VStack(alignment: .leading, spacing: 0) {
            QualityStatusCard(context: c, stats: stats)
            QualityHeading(title: "Path") { Text(pathCaption(c, stats)) }
                .padding(.top, 22)
            QualityPathCard(context: c, path: path, serverTitle: quality.server.provider == .cloudflare
                            ? "Cloudflare" : quality.server.shortTitle) { quality.tab = .servers }
            QualityHeading(title: "Ping, last 10 minutes") {
                LinkButton(title: "Earlier: History") { quality.tab = .history }
            }
            .padding(.top, 22)
            LiveChart(context: c)
            QualityHeading(title: "VPN today").padding(.top, 22)
            TodayCard()
        }
    }

    private func pathCaption(_ c: QualityContext?, _ s: PingStats?) -> String {
        guard let c else { return "" }
        guard let via = c.via else { return "Here only the VPN may go out" }
        let total = s?.median.map { "Where the \(Int($0.rounded())) ms go" } ?? "Where the time goes"
        return via == QualityVia.noVPN ? total : "\(total) · green is inside the VPN"
    }
}

// MARK: - Status card

struct QualityStatusCard: View {
    let context: QualityContext?
    let stats: PingStats?
    @EnvironmentObject private var quality: QualityMonitor

    var body: some View {
        let (title, detail, tone) = words
        let blocked = context == nil || context?.via == nil
        HStack(spacing: 16) {
            ZStack {
                if tone != .gray { StateGlow(tone: tone, width: 190, height: 150) }
                Circle()
                    .fill(tone == .gray ? Palette.tile : tone.fill.opacity(0.16))
                    .overlay(Circle().strokeBorder(tone == .gray ? Color.primary.opacity(0.1) : tone.fill.opacity(0.35)))
                    .frame(width: 52, height: 52)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tone == .gray ? Color.secondary : tone.text)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
            .frame(maxWidth: 300, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                number(blocked ? nil : stats?.median, unit: "ms", caption: "Ping",
                       warn: stats?.median.map(QualityLimits.pingIsHigh) ?? false)
                divider
                number(blocked ? nil : stats?.jitter, unit: "ms", caption: "Jitter",
                       warn: stats?.jitter.map(QualityLimits.jitterIsHigh) ?? false)
                divider
                number(blocked ? nil : stats.map { $0.loss * 100 }, unit: "%", caption: "Loss",
                       warn: stats.map { QualityLimits.lossIsHigh($0.loss) } ?? false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    private var divider: some View {
        Rectangle().fill(Palette.separator).frame(width: 1, height: 40)
    }

    private func number(_ v: Double?, unit: String, caption: String, warn: Bool) -> some View {
        QualityNumber(value: v.map { "\(Int($0.rounded()))" } ?? "–", unit: v == nil ? "" : unit, caption: caption,
                      warn: v != nil && warn)
            .frame(minWidth: 62, alignment: .trailing)
            .padding(.horizontal, 10)
    }

    private var words: (String, String, Tone) {
        guard let c = context else {
            return ("Not on a network", "Connect to Wi-Fi or a cable to measure.", .gray)
        }
        guard let via = c.via else {
            return ("Nothing to measure",
                    "\(c.vpnName ?? "The VPN") is not connected, and here only the VPN may reach the internet.", .gray)
        }
        guard let stats, stats.median != nil || stats.count >= 3 else {
            return ("Measuring", "The first checks come in a few seconds.", .gray)
        }
        let g = QualityGrade.of(stats)
        let why: String
        if via != QualityVia.noVPN {
            why = quality.windowOpen || quality.isPreview ? "Checked every 2 s while this window is open." : ""
        } else if c.paused {
            why = "Protection is paused, so no VPN is used."
        } else if c.trusted {
            why = "\(c.network) is trusted, so no VPN is used."
        } else {
            why = "Protection is off, so no VPN is used."
        }
        return (g.title, [g.advice, why].filter { !$0.isEmpty }.joined(separator: " "), g.tone)
    }
}

// MARK: - Path

/// This Mac → router → VPN server → test server, with the ms of each part.
struct QualityPathCard: View {
    let context: QualityContext?
    let path: QualityPath?
    let serverTitle: String
    let openServers: () -> Void

    private var viaVPN: Bool { context?.via != nil && context?.via != QualityVia.noVPN }
    private var blocked: Bool { context != nil && context?.via == nil }
    /// Without a VPN on a network that needs none: no VPN node.
    private var showsVPN: Bool { viaVPN || blocked }

    var body: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 0) {
                node(symbol: "laptopcomputer", tone: nil, title: "This Mac", detail: context?.cardLabel ?? "–")
                segment(path?.local, part: .local)
                node(symbol: routerSymbol, tone: context?.trusted == true ? .blue : .orange,
                     title: context?.network ?? "Router",
                     detail: context.map { $0.trusted ? "Router · trusted" : "Router · not trusted" } ?? "")
                if showsVPN {
                    segment(path?.road, part: .road)
                    node(symbol: blocked ? "xmark.shield" : "checkmark.shield", tone: blocked ? nil : .green,
                         title: context?.vpnName ?? "VPN", detail: blocked ? "Not connected" : "VPN server", dim: blocked)
                }
                segment(path?.internet, part: .internet)
                serverNode
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 14)
            if let path, let slow = path.slow, !blocked {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tone.orange.text)
                    (Text(slowTitle(slow)).fontWeight(.semibold) + Text(" " + slowDetail(slow, path)))
                        .font(.system(size: 12))
                        .foregroundStyle(Tone.orange.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Tone.orange.fill.opacity(0.10))
                .overlay(alignment: .top) { Rectangle().fill(Tone.orange.fill.opacity(0.25)).frame(height: 1) }
            }
        }
    }

    private var routerSymbol: String {
        guard let c = context else { return "wifi" }
        return c.cardLabel.localizedCaseInsensitiveContains("wi-fi") || c.network.contains("hotspot") ? "wifi" : "cable.connector"
    }

    private var serverNode: some View {
        VStack(spacing: 4) {
            circle(symbol: "server.rack", tone: nil, dim: blocked)
            Text(serverTitle).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                .foregroundStyle(blocked ? Color.secondary : Color.primary)
            Button(action: openServers) {
                Text("Test server").font(.system(size: 11)).foregroundStyle(Tone.blue.text)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .frame(width: 104)
    }

    private func node(symbol: String, tone: Tone?, title: String, detail: String, dim: Bool = false) -> some View {
        VStack(spacing: 4) {
            circle(symbol: symbol, tone: tone, dim: dim)
            Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                .foregroundStyle(dim ? Color.secondary : Color.primary)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 104)
    }

    private func circle(symbol: String, tone: Tone?, dim: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(dim ? Color.secondary : (tone?.text ?? Color.primary.opacity(0.75)))
            .frame(width: 36, height: 36)
            .background(Circle().fill(tone.map { $0.fill.opacity(0.16) } ?? Palette.tile))
    }

    @ViewBuilder
    private func segment(_ ms: Double?, part: QualityPath.Part) -> some View {
        let slow = path?.slow == part && !blocked
        let cut = blocked && part != .local
        let color: Color = slow ? Tone.orange.fill
            : (cut ? Color.primary.opacity(0.25)
               : (viaVPN && part != .internet ? Tone.green.fill : Color.primary.opacity(0.22)))
        VStack(spacing: 7) {
            Text(cut ? (part == .road ? "blocked" : " ") : QualityFormat.ms(ms))
                .font(.system(size: 12, weight: cut ? .regular : .semibold))
                .foregroundStyle(slow ? Tone.orange.text : (cut || ms == nil ? Color.secondary : Color.primary))
                .monospacedDigit()
            Group {
                if cut {
                    Line().stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 4]))
                } else {
                    Capsule().fill(color)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 4)
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }

    private func slowTitle(_ part: QualityPath.Part) -> String {
        switch part {
        case .local:
            let wifi = context?.cardLabel.localizedCaseInsensitiveContains("wi-fi") ?? true
            return wifi ? "The slow part is the Wi‑Fi itself:" : "The slow part is the local network itself:"
        case .road: return "The slow part is the way to the VPN server:"
        case .internet: return viaVPN ? "The slow part is behind the VPN server:" : "The slow part is the internet behind the router:"
        }
    }

    private func slowDetail(_ part: QualityPath.Part, _ p: QualityPath) -> String {
        let vpn = context?.vpnName ?? "the VPN"
        switch part {
        case .local:
            let rest = viaVPN ? "The VPN and the internet behind it are fine." : "The internet behind it is fine."
            return "\(QualityFormat.ms(p.local)) between this Mac and the router\(p.localJumps ? ", and it jumps" : ""). \(rest)"
        case .road:
            return "\(QualityFormat.ms(p.road)) between the router and \(vpn). A closer VPN server may help: try Compare."
        case .internet:
            return viaVPN ? "\(QualityFormat.ms(p.internet)) from \(vpn) to \(serverTitle). The Wi‑Fi and the way to the VPN are fine."
                          : "\(QualityFormat.ms(p.internet)) from the router to \(serverTitle). The Wi‑Fi is fine."
        }
    }
}

// MARK: - Live chart

private struct LiveChart: View {
    let context: QualityContext?
    @EnvironmentObject private var quality: QualityMonitor

    private struct Point: Identifiable {
        var id: String { "\(series)-\(at.timeIntervalSince1970)" }
        let at: Date
        let ms: Double
        let series: String
    }

    var body: some View {
        let now = Date()
        let from = now.addingTimeInterval(-600)
        let samples = context.flatMap { c in c.via.map { quality.history.pings(network: c.network, via: $0, since: from, target: quality.serverID) } } ?? []
        let target = "To \(quality.server.provider == .cloudflare ? "Cloudflare" : quality.server.shortTitle)"
        let viaVPN = context?.via != nil && context?.via != QualityVia.noVPN
        let main = QualityHistory.buckets(samples, value: { .some($0.internet) }, from: from, to: now, count: 60)
        let road = QualityHistory.buckets(samples, value: { $0.serverTried ? .some($0.server) : nil }, from: from, to: now, count: 60)
        let router = QualityHistory.buckets(samples, value: { $0.router.map { .some($0) } }, from: from, to: now, count: 60)
        let points = main.compactMap { b in b.ms.map { Point(at: b.at, ms: $0, series: target) } }
            + (viaVPN ? road.compactMap { b in b.ms.map { Point(at: b.at, ms: $0, series: "To the VPN server") } } : [])
            + router.compactMap { b in b.ms.map { Point(at: b.at, ms: $0, series: "To the router") } }
        let lost = main.filter(\.lost).map(\.at)
        let drops = quality.history.events.filter { $0.kind == .dropped && $0.at >= from }
        let colors: KeyValuePairs<String, Color> = [target: Tone.blue.fill, "To the VPN server": Tone.green.fill,
                                                    "To the router": Color.primary.opacity(0.3)]
        SettingsCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                if points.isEmpty {
                    Text(context?.via == nil ? "Nothing goes out here right now, so there is nothing to draw."
                                             : "No checks yet. The first ones appear in a few seconds.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 130)
                } else {
                    Chart {
                        ForEach(lost + drops.map(\.at), id: \.self) { t in
                            RectangleMark(xStart: .value("From", t.addingTimeInterval(-10)), xEnd: .value("To", t.addingTimeInterval(10)))
                                .foregroundStyle(Tone.orange.fill.opacity(0.18))
                        }
                        ForEach(points) { p in
                            LineMark(x: .value("Time", p.at), y: .value("Ping (ms)", p.ms))
                                .foregroundStyle(by: .value("Series", p.series))
                                .lineStyle(StrokeStyle(lineWidth: 1.8))
                                .interpolationMethod(.monotone)
                        }
                    }
                    .chartForegroundStyleScale(colors)
                    .chartLegend(.hidden)
                    .chartXScale(domain: from...now)
                    .chartXAxis {
                        AxisMarks(values: [from]) { _ in AxisValueLabel("10 min ago", anchor: .topLeading) }
                        AxisMarks(values: [from.addingTimeInterval(300)]) { _ in AxisValueLabel("5 min ago", anchor: .top) }
                        AxisMarks(values: [now]) { _ in AxisValueLabel("now", anchor: .topTrailing) }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let v = value.as(Double.self) { Text(v == 0 ? "0 ms" : "\(Int(v))") }
                            }
                        }
                    }
                    .frame(height: 130)
                }
                if !points.isEmpty { HStack(spacing: 14) {
                    Legend(color: Tone.blue.fill, text: target)
                    if viaVPN { Legend(color: Tone.green.fill, text: "To the VPN server") }
                    Legend(color: Color.primary.opacity(0.3), text: "To the router")
                    if let d = drops.last {
                        let back = quality.history.events.first { $0.kind == .up && $0.at > d.at }
                        Legend(color: Tone.orange.fill, text: "VPN dropped \(QualityFormat.duration(now.timeIntervalSince(d.at))) ago"
                               + (back.map { ", back in \(QualityFormat.duration($0.at.timeIntervalSince(d.at)))" } ?? ""), square: true)
                    } else if !lost.isEmpty {
                        Legend(color: Tone.orange.fill, text: "No answer", square: true)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1) }
            }
        }
    }
}

struct Legend: View {
    let color: Color
    let text: String
    var square = false
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if dashed {
                HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Circle().fill(color).frame(width: 3, height: 3) } }
            } else {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: square ? 8 : 12, height: square ? 8 : 3)
            }
            Text(text)
        }
    }
}

// MARK: - VPN today

private struct TodayCard: View {
    @EnvironmentObject private var quality: QualityMonitor

    var body: some View {
        let now = Date()
        let s = Stability(events: quality.history.events, from: Calendar.current.startOfDay(for: now), now: now)
        SettingsCard {
            HStack(spacing: 0) {
                item("Time protected", s.protectedShare.map { String(format: "%.1f %%", (($0 * 1000).rounded(.down)) / 10) } ?? "Not needed")
                bar
                item("Drops", s.drops == 0 ? "None" : "\(s.drops)" + (s.lastRecovery.map { " · back in \(QualityFormat.duration($0))" } ?? ""))
                bar
                item("Longest without a drop", s.longestUp.map(QualityFormat.duration) ?? "–")
                bar
                item("Time to connect", s.averageConnect.map(QualityFormat.duration) ?? "–")
            }
            .padding(.vertical, 12)
        }
    }

    private var bar: some View { Rectangle().fill(Palette.separator).frame(width: 1, height: 34) }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }
}

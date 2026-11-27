import Charts
import SwiftUI
import UniformTypeIdentifiers
import VPNGuardCore

/// History: charts over time, every test, the events log, export and clear.
struct QualityHistoryPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor
    @State private var range: HistoryRange = .week
    /// Nil: all networks.
    @State private var network: String?
    /// Connections hidden in the charts.
    @State private var hidden: Set<String> = []
    @State private var showUpload = false
    @State private var sort = TestSort(column: .time, ascending: false)
    @State private var allTests = false
    @State private var allEvents = false

    enum HistoryRange: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", year = "1 year"
        var id: String { rawValue }
        var days: Int { self == .week ? 7 : (self == .month ? 30 : 365) }
        var unit: Calendar.Component { self == .year ? .weekOfYear : .day }
    }

    var body: some View {
        let now = Date()
        let from = Calendar.current.startOfDay(for: now.addingTimeInterval(-Double(range.days - 1) * 86_400))
        let h = quality.history
        let tests = h.tests(network: network, since: from)
        let events = h.eventLog(network: network, since: from)
        VStack(alignment: .leading, spacing: 0) {
            toolbar(from: from)
            QualityHeading(title: "Over time").padding(.top, 20)
            overTime(from: from, to: now)
            QualityHeading(title: "Tests") { Text("Speeds in Mbps") }.padding(.top, 22)
            testsTable(tests)
            QualityHeading(title: "Events") { Text("What happened to the VPN and the network") }.padding(.top, 22)
            eventsTable(events)
            Text("Kept on this Mac only. Tests and events: 1 year. Background ping points: 7 days, then one number per day.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 10)
        }
    }

    // MARK: Toolbar

    private func toolbar(from: Date) -> some View {
        HStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Menu {
                Button("All networks") { network = nil }
                Divider()
                ForEach(quality.history.networks, id: \.self) { n in Button(n) { network = n } }
            } label: {
                Text(network ?? "All networks").font(.system(size: 12))
            }
            .menuStyle(.button)
            .fixedSize()
            Spacer()
            Button("Export CSV…") { export(from: from) }
                .buttonStyle(CardButtonStyle())
                .disabled(quality.history.tests.isEmpty && quality.history.events.isEmpty)
            Button("Clear History…") { clear() }
                .buttonStyle(CardButtonStyle(destructive: true))
                .disabled(quality.history.isEmpty)
        }
    }

    private func export(from: Date) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Network Quality.csv"
        panel.message = "Tests and events of the last \(range.rawValue)" + (network.map { " on \($0)" } ?? "") + "."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try quality.csv(network: network, since: from).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Dialogs.error("Could not save the file", error.localizedDescription)
        }
    }

    private func clear() {
        guard Dialogs.confirm(title: "Clear the network quality history?",
                              message: "Every test, event and ping point kept on this Mac is deleted. This cannot be undone.",
                              button: "Clear History") else { return }
        quality.clearHistory()
    }

    // MARK: Over time

    private func overTime(from: Date, to: Date) -> some View {
        let points = quality.history.trend(network: network, target: quality.serverID, from: from, to: to, unit: range.unit)
        // Room after today's point, so its label shows.
        let end = Calendar.current.date(byAdding: range == .year ? .weekOfYear : .day, value: 1,
                                        to: Calendar.current.startOfDay(for: to)) ?? to
        var order = Array(Set(points.map(\.via))).sorted()
        if let mine = model.selectedVPN?.name, let i = order.firstIndex(of: mine) { order.insert(order.remove(at: i), at: 0) }
        if let i = order.firstIndex(of: QualityVia.noVPN) { order.append(order.remove(at: i)) }
        let shown = points.filter { !hidden.contains($0.via) }
        return SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                if order.isEmpty {
                    Text("Nothing measured in this time yet. Run a test on the Compare tab, or turn on the background checks below.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(order, id: \.self) { via in
                            Legend(color: ConnectionColors.color(via, order: order), text: via, dashed: via == QualityVia.noVPN)
                                .font(.system(size: 12))
                                .foregroundStyle(hidden.contains(via) ? Color.secondary : Color.primary)
                                .opacity(hidden.contains(via) ? 0.5 : 1)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(ChipShape().fill(Palette.cardFill))
                                .overlay(ChipShape().strokeBorder(Color.primary.opacity(0.14)))
                                .contentShape(ChipShape())
                                .onTapGesture {
                                    if hidden.contains(via) { hidden.remove(via) } else { hidden.insert(via) }
                                }
                                .accessibilityAddTraits(.isButton)
                            .help(hidden.contains(via) ? "Show \(via)" : "Hide \(via)")
                        }
                    }
                    HStack(alignment: .top, spacing: 22) {
                        trendChart(title: "Ping", unit: "ms, lower is better", points: shown, order: order, from: from, to: end) { $0.ping }
                        trendChart(title: showUpload ? "Upload" : "Download", unit: "Mbps, higher is better", points: shown,
                                   order: order, from: from, to: end,
                                   trailing: AnyView(LinkButton(title: showUpload ? "Show download" : "Show upload") { showUpload.toggle() })) {
                            showUpload ? $0.up : $0.down
                        }
                    }
                }
            }
            .padding(14)
            RowDivider(leading: 0)
            ToggleRow(title: "Keep checking in the background",
                      detail: "Adds a ping point every 60 s (a few bytes). Off: only your tests are in the charts.",
                      isOn: $quality.backgroundOn)
        }
    }

    private struct Mark: Identifiable {
        var id: String { "\(via)-\(at.timeIntervalSince1970)" }
        let via: String
        let at: Date
        let value: Double
    }

    private func trendChart(title: String, unit: String, points: [TrendPoint], order: [String], from: Date, to: Date,
                            trailing: AnyView? = nil, value: (TrendPoint) -> Double?) -> some View {
        let marks = points.compactMap { p in value(p).map { Mark(via: p.via, at: p.at, value: $0) } }
        let vias = order.filter { v in marks.contains { $0.via == v } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(unit).font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let trailing { trailing }
            }
            if marks.isEmpty {
                Text(title == "Ping" ? "No pings in this time." : "No speed tests in this time.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart(marks) { m in
                    LineMark(x: .value("Day", m.at), y: .value(title, m.value))
                        .foregroundStyle(by: .value("Connection", m.via))
                        .lineStyle(StrokeStyle(lineWidth: 1.8, dash: m.via == QualityVia.noVPN ? [2, 3] : []))
                    PointMark(x: .value("Day", m.at), y: .value(title, m.value))
                        .foregroundStyle(by: .value("Connection", m.via))
                        .symbolSize(16)
                }
                .chartForegroundStyleScale(domain: vias, range: vias.map { ConnectionColors.color($0, order: order) })
                .chartLegend(.hidden)
                .chartXScale(domain: from...to)
                .chartXAxis {
                    AxisMarks(values: .stride(by: range == .year ? .month : .day, count: range == .month ? 5 : 1)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: range == .year ? .dateTime.month(.abbreviated) : .dateTime.day())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 120)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Tests

    struct TestSort: Equatable {
        enum Column { case time, network, connection, server, ping, jitter, loss, down, up }
        var column: Column
        var ascending: Bool
    }

    private enum TW {
        static let time: CGFloat = 92, network: CGFloat = 98, server: CGFloat = 70, ping: CGFloat = 48, jitter: CGFloat = 46,
                   loss: CGFloat = 38, down: CGFloat = 46, up: CGFloat = 42
    }

    private func sorted(_ tests: [QualityTest]) -> [QualityTest] {
        func key(_ t: QualityTest) -> Double? {
            switch sort.column {
            case .ping: return t.ping
            case .jitter: return t.jitter
            case .loss: return t.loss
            case .down: return t.downMbps
            case .up: return t.upMbps
            default: return nil
            }
        }
        return tests.sorted { a, b in
            let asc: Bool
            switch sort.column {
            case .time: asc = a.at < b.at
            case .network: asc = a.network.localizedCaseInsensitiveCompare(b.network) == .orderedAscending
            case .connection: asc = a.via.localizedCaseInsensitiveCompare(b.via) == .orderedAscending
            case .server: asc = a.server < b.server
            default:
                // Empty values last either way.
                switch (key(a), key(b)) {
                case let (x?, y?): return sort.ascending ? x < y : x > y
                case (_?, nil): return true
                default: return false
                }
            }
            return sort.ascending ? asc : !asc
        }
    }

    private func testsTable(_ tests: [QualityTest]) -> some View {
        let rows = sorted(tests)
        let visible = allTests ? rows : Array(rows.prefix(6))
        return SettingsCard {
            HStack(spacing: 8) {
                head("Time", .time, width: TW.time)
                head("Network", .network, width: TW.network)
                head("Connection", .connection, width: nil)
                head("Server", .server, width: TW.server)
                head("Ping", .ping, width: TW.ping, right: true)
                head("Jitter", .jitter, width: TW.jitter, right: true)
                head("Loss", .loss, width: TW.loss, right: true)
                head("Down", .down, width: TW.down, right: true)
                head("Up", .up, width: TW.up, right: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if rows.isEmpty {
                RowDivider(leading: 0)
                Text("No tests in this time. Run one on the Compare tab.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 34)
            }
            LazyVStack(spacing: 0) {
                ForEach(visible) { t in
                    RowDivider(leading: 0)
                    HStack(spacing: 8) {
                        Cell(text: t.at.qualityDayTime, width: TW.time, color: .secondary)
                        Cell(text: t.network, width: TW.network)
                        Cell(text: t.via, weight: .medium)
                        Cell(text: TestServers.server(id: t.server).shortTitle, width: TW.server, color: .secondary)
                        Cell(text: QualityFormat.ms(t.ping), width: TW.ping, alignment: .trailing,
                             weight: warn(t.ping, QualityLimits.pingIsHigh) ? .semibold : .regular,
                             color: warn(t.ping, QualityLimits.pingIsHigh) ? Tone.orange.text : .primary)
                        Cell(text: QualityFormat.ms(t.jitter), width: TW.jitter, alignment: .trailing,
                             weight: warn(t.jitter, QualityLimits.jitterIsHigh) ? .semibold : .regular,
                             color: warn(t.jitter, QualityLimits.jitterIsHigh) ? Tone.orange.text : .primary)
                        Cell(text: QualityFormat.percent(t.loss), width: TW.loss, alignment: .trailing,
                             weight: warn(t.loss, QualityLimits.lossIsHigh) ? .semibold : .regular,
                             color: warn(t.loss, QualityLimits.lossIsHigh) ? Tone.orange.text : .primary)
                        Cell(text: QualityFormat.mbps(t.downMbps), width: TW.down, alignment: .trailing,
                             color: t.downMbps == nil ? .secondary : .primary)
                        Cell(text: QualityFormat.mbps(t.upMbps), width: TW.up, alignment: .trailing,
                             color: t.upMbps == nil ? .secondary : .primary)
                    }
                    .padding(.horizontal, 14).frame(height: 33)
                }
            }
            if rows.count > 6 {
                footer(shown: visible.count, of: rows.count, all: $allTests)
            }
        }
    }

    private func warn(_ v: Double?, _ high: (Double) -> Bool) -> Bool { v.map(high) ?? false }

    private func head(_ title: String, _ column: TestSort.Column, width: CGFloat?, right: Bool = false) -> some View {
        let active = sort.column == column
        return Button {
            if active { sort.ascending.toggle() } else { sort = TestSort(column: column, ascending: column != .time && column != .down && column != .up) }
        } label: {
            HStack(spacing: 3) {
                if right { Spacer(minLength: 0) }
                Text(title).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                if active {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7.5, weight: .bold)).foregroundStyle(.secondary)
                }
                if !right { Spacer(minLength: 0) }
            }
            .lineLimit(1)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
    }

    private func footer(shown: Int, of total: Int, all: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            RowDivider(leading: 0)
            HStack {
                Text(all.wrappedValue ? "Showing all \(total)" : "Showing \(shown) of \(total)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(all.wrappedValue ? "Show Less" : "Show All") { all.wrappedValue.toggle() }
                    .buttonStyle(CardButtonStyle())
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    // MARK: Events

    private enum EW {
        static let time: CGFloat = 92, network: CGFloat = 98, what: CGFloat = 236
    }

    private func eventsTable(_ events: [EventLine]) -> some View {
        let visible = allEvents ? events : Array(events.prefix(3))
        return SettingsCard {
            HStack(spacing: 8) {
                Cell(text: "Time", width: EW.time, weight: .semibold, color: .secondary, size: 11.5)
                Cell(text: "Network", width: EW.network, weight: .semibold, color: .secondary, size: 11.5)
                Cell(text: "What happened", width: EW.what, weight: .semibold, color: .secondary, size: 11.5)
                Cell(text: "Details", weight: .semibold, color: .secondary, size: 11.5)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            if events.isEmpty {
                RowDivider(leading: 0)
                Text("Nothing happened in this time: no drops, failed connections or unstable times.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 34)
            }
            ForEach(Array(visible.enumerated()), id: \.offset) { _, e in
                RowDivider(leading: 0)
                HStack(spacing: 8) {
                    Cell(text: e.at.qualityDayTime, width: EW.time, color: .secondary)
                    Cell(text: e.network ?? "–", width: EW.network, color: e.network == nil ? .secondary : .primary)
                    HStack(spacing: 7) {
                        Circle().fill(e.tone == .red ? Tone.red.fill : Tone.orange.fill).frame(width: 7, height: 7)
                        Text(e.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    }
                    .frame(width: EW.what, alignment: .leading)
                    Cell(text: e.detail.isEmpty ? "–" : e.detail, color: .secondary)
                        .help(e.detail)
                }
                .padding(.horizontal, 14).frame(height: 33)
            }
            if events.count > 3 {
                footer(shown: visible.count, of: events.count, all: $allEvents)
            }
        }
    }
}

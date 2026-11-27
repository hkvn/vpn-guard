import SwiftUI
import VPNGuardCore

/// Compare: one test for one or more connections, run in place; the results table with a verdict.
struct QualityComparePage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor
    /// The network whose results are shown (nil: where the Mac is now).
    @State private var shownNetwork: String?
    @State private var ready = false

    var body: some View {
        let c = model.qualityContext
        let run = quality.run
        VStack(alignment: .leading, spacing: 0) {
            QualityHeading(title: "New test")
            setupCard(c, run)
            Text(hint(c, run))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 8)
            if let note = quality.runNote, run == nil {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Tone.orange.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 6)
            }
            resultsHeading(c, run).padding(.top, 22)
            ResultsTable(network: network(c, run), context: c, run: run)
            if run != nil {
                Text("Each row fills in when its test ends. Pausing protection, turning it off or changing network stops the test.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 8)
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            if quality.picked.isEmpty {
                quality.picked = Set(model.comparableVPNs.map(\.id))
                if c?.directAllowed == true { quality.picked.insert(QualityMonitor.noVPNID) }
                quality.withSpeed = !quality.costlyNetwork
            }
        }
    }

    private func network(_ c: QualityContext?, _ run: QualityMonitor.TestRun?) -> String {
        run?.network ?? shownNetwork ?? c?.network ?? quality.history.networks.first ?? "this network"
    }

    // MARK: Setup

    private func setupCard(_ c: QualityContext?, _ run: QualityMonitor.TestRun?) -> some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 0) {
                Text("Compare").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 8) {
                    FlowLayout(spacing: 6) {
                        if let run {
                            ForEach(run.items) { Chip(title: $0.name, state: .on) }
                        } else {
                            ForEach(model.comparableVPNs) { v in
                                Chip(title: v.name, state: quality.picked.contains(v.id) ? .on : .off) { toggle(v.id) }
                            }
                            Chip(title: QualityVia.noVPN,
                                 state: c?.directAllowed == true ? (quality.picked.contains(QualityMonitor.noVPNID) ? .on : .off) : .locked) {
                                toggle(QualityMonitor.noVPNID)
                            }
                            ForEach(model.vpnServices.filter { v in !model.comparableVPNs.contains { $0.id == v.id } }) { v in
                                Chip(title: v.name, state: .unavailable)
                            }
                        }
                    }
                    if run == nil, let why = unavailableText(c) {
                        Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            RowDivider(leading: 0)
            if let run {
                runningRow(run)
            } else {
                measureRow(c)
            }
        }
    }

    private func toggle(_ id: String) {
        if quality.picked.contains(id) { quality.picked.remove(id) } else { quality.picked.insert(id) }
    }

    private func unavailableText(_ c: QualityContext?) -> String? {
        var parts: [String] = []
        if c?.directAllowed != true { parts.append("No VPN can be tested on a trusted network, or while protection is paused.") }
        for v in model.vpnServices where !model.comparableVPNs.contains(where: { $0.id == v.id }) {
            if v.isPartial {
                parts.append("\(v.name) only carries \(model.partialNetworkName(v).map { "\($0) addresses" } ?? "some addresses").")
            } else if v.isOtherApp {
                parts.append("\(v.name) belongs to another app.")
            } else {
                parts.append("\(v.name) needs a fix first (Settings › VPN).")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func measureRow(_ c: QualityContext?) -> some View {
        let items = quality.plannedItems()
        return HStack(spacing: 12) {
            Text("Measure").font(.system(size: 12.5)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Picker("Measure", selection: $quality.withSpeed) {
                Text("Ping").tag(false)
                Text("Ping + speed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(estimate(items))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button("Run Test") { quality.startRun() }
                .buttonStyle(CardButtonStyle(prominent: true))
                .disabled(items.isEmpty || c?.network == nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func estimate(_ items: [QualityMonitor.TestRun.Item]) -> String {
        guard !items.isEmpty else { return "Pick at least one connection" }
        let via = model.qualityContext?.via
        let secs = items.reduce(0.0) { $0 + QualityMonitor.estimate(seconds: quality.withSpeed, switching: $1.name != via) }
        let time = secs < 90 ? "\(Int((secs / 10).rounded()) * 10) s" : "\(Int((secs / 60).rounded())) min"
        guard quality.withSpeed else { return "About \(time) · almost no data" }
        let mb = items.count * QualityMonitor.speedMegabytes
        let data = mb >= 1000 ? "\(Int((Double(mb) / 1000).rounded())) GB" : "\(mb) MB"
        return "About \(time) · up to \(data) of data"
    }

    private func runningRow(_ run: QualityMonitor.TestRun) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 12) {
                Text("Running").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    // Drawn, not a ProgressView: that one turns gray when the window is not in front.
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(Tone.blue.fill).frame(width: max(6, g.size.width * progress(run, now: ctx.date)))
                        }
                    }
                    .frame(height: 5)
                    Text(runningText(run, now: ctx.date))
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Button("Stop") { quality.stopRun() }
                    .buttonStyle(CardButtonStyle())
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
        }
    }

    private func progress(_ run: QualityMonitor.TestRun, now: Date) -> Double {
        let total = run.items.reduce(0.0) { $0 + QualityMonitor.estimate(seconds: run.withSpeed, switching: $1.name != run.startedWith) }
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - Double(run.secondsLeft(now: now)) / total))
    }

    private func runningText(_ run: QualityMonitor.TestRun, now: Date) -> String {
        guard let i = run.current else { return "Finishing…" }
        let item = run.items[i]
        let step: String
        switch item.step {
        case .connecting: step = item.id == QualityMonitor.noVPNID ? "taking the VPN down" : "connecting"
        case .ping: step = "measuring ping"
        case .speed: step = "testing speed"
        default: step = ""
        }
        let left = run.secondsLeft(now: now)
        let time = left < 90 ? "\(max(5, Int((Double(left) / 5).rounded()) * 5)) s" : "\(Int((Double(left) / 60).rounded())) min"
        return "\(item.name), \(i + 1) of \(run.items.count) · \(step) · about \(time) left"
    }

    private func hint(_ c: QualityContext?, _ run: QualityMonitor.TestRun?) -> String {
        let back: String
        if let via = c?.via, via != QualityVia.noVPN {
            back = via
        } else if c?.via == QualityVia.noVPN {
            back = "normal internet"
        } else {
            back = c?.vpnName ?? "your VPN"
        }
        if let run {
            if run.items.count == 1 { return "Only \(run.items[0].name) is tested, so nothing switches." }
            return "Only the connection being tested can reach the internet right now. When the test ends, VPN Guard goes back to \(back)."
        }
        let items = quality.plannedItems()
        if items.count == 1, items[0].name == c?.via {
            return "Only \(items[0].name) is tested, so nothing switches."
        }
        return "VPN Guard connects each one in turn, then goes back to \(back). Your internet pauses while it switches; the lock stays on."
    }

    // MARK: Results

    private func resultsHeading(_ c: QualityContext?, _ run: QualityMonitor.TestRun?) -> some View {
        let shown = network(c, run)
        var names = quality.history.networks
        if let here = c?.network, !names.contains(here) { names.insert(here, at: 0) }
        return HStack(spacing: 8) {
            Text("Results on").font(.system(size: 13, weight: .semibold))
            Menu {
                ForEach(names, id: \.self) { n in
                    Button(n == c?.network ? "\(n) (here)" : n) { shownNetwork = n }
                }
            } label: {
                Text(shown).font(.system(size: 12))
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(run != nil || names.count < 2)
            Spacer()
            Text("Measured against \(quality.server.shortTitle)")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Chips

private struct Chip: View {
    enum State { case on, off, locked, unavailable }
    let title: String
    let state: State
    var action: (() -> Void)?

    private var interactive: Bool { action != nil && (state == .on || state == .off) }

    var body: some View {
        HStack(spacing: 5) {
            switch state {
            case .on: Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
            case .locked: Image(systemName: "lock.fill").font(.system(size: 9))
            case .unavailable: Image(systemName: "minus").font(.system(size: 9.5, weight: .bold))
            case .off: EmptyView()
            }
            Text(title).font(.system(size: 12.5, weight: state == .on ? .medium : .regular))
        }
        .foregroundStyle(state == .on ? Tone.blue.text : (state == .off ? Color.primary : Color.secondary))
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(ChipShape().fill(state == .on ? Tone.blue.fill.opacity(0.12)
                                     : (state == .off ? Palette.cardFill : Color.primary.opacity(0.04))))
        .overlay(ChipShape().strokeBorder(state == .on ? Tone.blue.fill.opacity(0.45) : Color.primary.opacity(0.14)))
        .contentShape(ChipShape())
        .onTapGesture { if interactive { action?() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(interactive ? [.isButton] : [])
        .accessibilityAddTraits(state == .on ? .isSelected : [])
        .accessibilityAction { if interactive { action?() } }
    }
}

/// A pill outline. (A Capsule's stroke drew small ticks at its ends in the rendered window.)
struct ChipShape: InsettableShape {
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(cornerRadius: max(0, r.height / 2 - 1), style: .circular).path(in: r)
    }
    func inset(by amount: CGFloat) -> ChipShape { ChipShape(inset: inset + amount) }
}

/// Lays chips out in rows, wrapping when the row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

// MARK: - Results table

private struct ResultsTable: View {
    let network: String
    let context: QualityContext?
    let run: QualityMonitor.TestRun?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor

    private enum W {
        static let ping: CGFloat = 66, jitter: CGFloat = 58, loss: CGFloat = 50, down: CGFloat = 96, up: CGFloat = 90, tested: CGFloat = 50
    }

    private struct Row: Identifiable {
        var id: String { via }
        var via: String
        var test: QualityTest?
        var item: QualityMonitor.TestRun.Item?
        var inRun: Bool
    }

    var body: some View {
        let latest = quality.history.latestTests(network: network, server: quality.serverID)
        let rows = makeRows(latest)
        let verdict = run == nil ? CompareVerdict.decide(rows.compactMap(\.test), current: currentVia) : nil
        let best = Best(rows.compactMap(\.test))
        SettingsCard {
            if let verdict { verdictBanner(verdict) }
            header
            ForEach(rows) { r in
                RowDivider(leading: 0)
                row(r, best: best, verdictBest: verdict?.best)
            }
        }
    }

    /// The VPN in use here (for "your VPN" and the verdict).
    private var currentVia: String? {
        context?.network == network ? (context?.via ?? context?.vpnName) : model.selectedVPN?.name
    }

    private func makeRows(_ latest: [String: QualityTest]) -> [Row] {
        var names = model.comparableVPNs.map(\.name)
        if let mine = model.selectedVPN?.name, let i = names.firstIndex(of: mine) { names.insert(names.remove(at: i), at: 0) }
        names += latest.keys.filter { $0 != QualityVia.noVPN && !names.contains($0) }.sorted()
        names.append(QualityVia.noVPN)
        return names.map { via in
            let item = run?.items.first { $0.name == via }
            return Row(via: via, test: run == nil ? latest[via] : (item?.test ?? nil), item: item, inRun: item != nil)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Cell(text: "Connection", weight: .semibold, color: .secondary, size: 11.5)
            Cell(text: "Ping", width: W.ping, weight: .semibold, color: .secondary, size: 11.5)
            Cell(text: "Jitter", width: W.jitter, weight: .semibold, color: .secondary, size: 11.5)
            Cell(text: "Loss", width: W.loss, weight: .semibold, color: .secondary, size: 11.5)
            Cell(text: "Download", width: W.down, weight: .semibold, color: .secondary, size: 11.5)
            Cell(text: "Upload", width: W.up, weight: .semibold, color: .secondary, size: 11.5)
            Cell(text: "Tested", width: W.tested, weight: .semibold, color: .secondary, size: 11.5)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func verdictBanner(_ v: CompareVerdict) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Tone.green.fill)
            (Text(v.headline).fontWeight(.semibold) + Text(v.detail.isEmpty ? "" : " " + v.detail))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if !v.bestIsCurrent, context?.network == network, let vpn = model.comparableVPNs.first(where: { $0.name == v.best }) {
                Button("Use \(v.best)") { model.choose(vpn) }
                    .buttonStyle(CardButtonStyle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Tone.green.fill.opacity(0.09))
        .overlay(alignment: .bottom) { Rectangle().fill(Tone.green.fill.opacity(0.2)).frame(height: 1) }
    }

    @ViewBuilder
    private func row(_ r: Row, best: Best, verdictBest: String?) -> some View {
        let isBest = verdictBest == r.via
        let running = run != nil
        let dim = running && !r.inRun
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                if running {
                    stepIcon(r.item?.step).frame(width: 16)
                }
                Text(r.via).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(dim || (r.test == nil && !running) ? Color.secondary : Color.primary)
                if r.via == currentVia, r.via != QualityVia.noVPN, !running {
                    Text("your VPN").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if isBest { Pill(text: "Best", tone: .green) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if dim {
                spanning("Not in this test.")
                Cell(text: "–", width: W.tested, color: .secondary)
            } else if let item = r.item, running, item.step == .waiting || item.step == .connecting || item.step == .skipped {
                spanning(item.step == .connecting ? "Connecting…" : (item.step == .skipped ? "Not tested" : "Waiting"))
                Cell(text: "–", width: W.tested, color: .secondary)
            } else if let item = r.item, running, case .failed(let why) = item.step {
                spanning(why, color: Tone.red.text)
                Cell(text: "–", width: W.tested, color: .secondary)
            } else if let item = r.item, running, item.step == .ping {
                spanning("Measuring ping…", color: Tone.blue.text)
                Cell(text: "–", width: W.tested, color: .secondary)
            } else if let t = r.test {
                value(QualityFormat.ms(t.ping), width: W.ping, best: best.ping == r.via, warn: t.ping.map(QualityLimits.pingIsHigh) ?? false)
                value(QualityFormat.ms(t.jitter), width: W.jitter, best: best.jitter == r.via,
                      warn: t.jitter.map(QualityLimits.jitterIsHigh) ?? false)
                value(QualityFormat.percent(t.loss), width: W.loss, best: false, warn: t.loss.map(QualityLimits.lossIsHigh) ?? false)
                if let item = r.item, item.step == .speed {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(0, Int(QualityMonitor.fullSpeedSeconds - ctx.date.timeIntervalSince(item.stepStarted ?? ctx.date)))
                        Cell(text: "Testing speed… \(left) s left", color: Tone.blue.text, size: 12)
                    }
                    .frame(width: W.down + W.up + 8, alignment: .leading)
                    Cell(text: "–", width: W.tested, color: .secondary)
                } else {
                    value(t.downMbps.map { "\(QualityFormat.mbps($0)) Mbps" } ?? (t.ping != nil ? "ping only" : "–"), width: W.down,
                          best: best.down == r.via, warn: false, muted: t.downMbps == nil)
                    value(t.upMbps.map { "\(QualityFormat.mbps($0)) Mbps" } ?? "–", width: W.up, best: best.up == r.via, warn: false,
                          muted: t.upMbps == nil)
                    Cell(text: running ? "now" : t.at.qualityShort, width: W.tested, color: .secondary, size: 12)
                }
            } else {
                spanning(r.via == QualityVia.noVPN && context?.directAllowed != true && context?.network == network
                         ? "Not tested here. Pause protection to test without the VPN."
                         : "Not tested on this network.")
                Cell(text: "–", width: W.tested, color: .secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(r.item.map { [.connecting, .ping, .speed].contains($0.step) } == true ? Tone.blue.fill.opacity(0.06) : Color.clear)
    }

    private func spanning(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(color).lineLimit(1)
            .frame(width: W.ping + W.jitter + W.loss + W.down + W.up + 32, alignment: .leading)
    }

    private func value(_ text: String, width: CGFloat, best: Bool, warn: Bool, muted: Bool = false) -> some View {
        Cell(text: text, width: width, weight: best ? .semibold : .regular,
             color: muted ? .secondary : (warn ? Tone.orange.text : (best ? Tone.green.text : .primary)))
    }

    @ViewBuilder
    private func stepIcon(_ step: QualityMonitor.TestRun.Step?) -> some View {
        switch step {
        case .done?:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Tone.green.fill)
        case .failed?:
            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Tone.red.fill)
        case .connecting?, .ping?, .speed?:
            ProgressView().controlSize(.mini)
        case .waiting?, .skipped?:
            Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(.tertiary)
        case nil:
            Color.clear
        }
    }

    /// Which row has the best value in each column (only when it is clearly the one).
    private struct Best {
        var ping: String?, jitter: String?, down: String?, up: String?
        init(_ tests: [QualityTest]) {
            let vpns = tests.filter { $0.via != QualityVia.noVPN }
            guard vpns.count > 1 else { return }
            func pick(_ value: (QualityTest) -> Double?, lowest: Bool) -> String? {
                let xs = vpns.compactMap { t in value(t).map { (t.via, $0) } }.sorted { lowest ? $0.1 < $1.1 : $0.1 > $1.1 }
                guard xs.count > 1, abs(xs[0].1 - xs[1].1) >= 1 else { return nil }
                return xs[0].0
            }
            ping = pick({ $0.ping }, lowest: true)
            jitter = pick({ $0.jitter }, lowest: true)
            down = pick({ $0.downMbps }, lowest: false)
            up = pick({ $0.upMbps }, lowest: false)
        }
    }
}

import SwiftUI
import VPNGuardCore

// The Network Quality window (design canvas row 15: Monitor, Compare, History, Servers).
// Same shape as Settings: icon tabs on top under a hidden title bar, the page below.

struct QualityView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor
    @State private var barHeight: CGFloat = 0
    @State private var pageHeight: CGFloat = 0

    /// As tall as the page, unless the screen is too small (then the page scrolls).
    private var height: CGFloat {
        guard barHeight > 0, pageHeight > 0 else { return 640 }
        let screen = model.isPreview ? 4000 : (NSScreen.main?.visibleFrame.height ?? 900) - 40
        return max(320, min(barHeight + pageHeight, screen)) - titleBarHeight
    }

    private var titleBarHeight: CGFloat {
        guard !model.isPreview else { return 0 }
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height - content.height
    }

    var body: some View {
        VStack(spacing: 0) {
            QualityTopBar()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            ScrollView {
                Group {
                    switch quality.tab {
                    case .monitor: QualityMonitorPage()
                    case .compare: QualityComparePage()
                    case .history: QualityHistoryPage()
                    case .servers: QualityServersPage()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.window)
        .ignoresSafeArea(edges: .top)
        .frame(width: 700, height: height)
        .onAppear { quality.windowOpened() }
        .onDisappear { quality.windowClosed() }
        .onChange(of: quality.tab) { _, tab in
            if tab == .servers, quality.serverTimes.isEmpty { quality.measureServers() }
        }
    }
}

// MARK: - Top bar

private struct QualityTopBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Network Quality")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                HStack {
                    Spacer()
                    QualityStatusChip()
                }
                .padding(.trailing, 12)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            HStack(spacing: 6) {
                ForEach(QualityTab.allCases) { tab($0) }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.header)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }

    private func tab(_ t: QualityTab) -> some View {
        let selected = quality.tab == t
        return Button { quality.tab = t } label: {
            VStack(spacing: 4) {
                Image(systemName: t.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(t.color))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                Text(t.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .frame(width: 96)
            .padding(.top, 6)
            .padding(.bottom, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.08) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// "Stable · 38 ms" on the right of the title bar, or "Testing · 2 of 3".
private struct QualityStatusChip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor

    var body: some View {
        let (text, tone) = look
        HStack(spacing: 6) {
            Circle().fill(tone.fill).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(tone.text).monospacedDigit()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.fill.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }

    private var look: (String, Tone) {
        if let run = quality.run {
            return ("Testing · \(min(run.doneCount + 1, run.items.count)) of \(run.items.count)", .blue)
        }
        guard let c = model.qualityContext else { return ("No network", .gray) }
        guard c.via != nil else { return ("Blocked", .gray) }
        guard let s = quality.recentStats(), let m = s.median else { return ("Measuring", .gray) }
        let g = QualityGrade.of(s)
        return ("\(g.title) · \(Int(m.rounded())) ms", g.tone)
    }
}

extension QualityGrade {
    var tone: Tone {
        switch self {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - Shared pieces

/// A section title with an optional caption or link on the right.
struct QualityHeading<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            trailing()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

extension QualityHeading where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        trailing = { EmptyView() }
    }
}

/// Blue text that acts like a link (not underlined).
struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).foregroundStyle(Tone.blue.text)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

/// A big number with its unit and a caption under it: "38 ms / Ping".
struct QualityNumber: View {
    let value: String
    let unit: String
    let caption: String
    var warn = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(warn ? Tone.orange.text : Color.primary)
                Text(unit).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A table header cell or value cell with a fixed width.
struct Cell: View {
    let text: String
    var width: CGFloat?
    var alignment: Alignment = .leading
    var weight: Font.Weight = .regular
    var color: Color = .primary
    var size: CGFloat = 12.5

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

/// Colors for connections in charts: the chosen VPN blue, then a fixed order; No VPN gray.
enum ConnectionColors {
    static let palette: [Color] = [Tone.blue.fill, Color(hex: 0x2E9E4F), Tone.orange.fill, Color(hex: 0x8E5CE6),
                                   Color(hex: 0x00A3A3), Color(hex: 0xE0457B)]

    static func color(_ via: String, order: [String]) -> Color {
        if via == QualityVia.noVPN { return Color.primary.opacity(0.55) }
        let i = order.firstIndex(of: via) ?? order.count
        return palette[i % palette.count]
    }
}

extension Date {
    /// "14:02" today, "26 Nov 14:02" before.
    var qualityShort: String {
        Calendar.current.isDateInToday(self) ? formatted(date: .omitted, time: .shortened) : qualityDayTime
    }

    /// "27 Nov 14:04".
    var qualityDayTime: String {
        formatted(.dateTime.day().month(.abbreviated)) + " " + formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Popover row

/// "Network quality · ● 38 ms · Stable" under the VPN card; opens the window.
struct QualityRow: View {
    @ObservedObject var quality: QualityMonitor
    let open: () -> Void

    var body: some View {
        let s = quality.recentStats()
        let grade = s.map(QualityGrade.of) ?? .unknown
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text("Network quality").font(.system(size: 12, weight: .medium))
                Spacer()
                if let m = s?.median, grade != .unknown {
                    Circle().fill(grade.tone.fill).frame(width: 7, height: 7)
                    Text("\(Int(m.rounded())) ms · \(grade.title)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Open").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.cardBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Network Quality")
    }
}

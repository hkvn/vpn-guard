import SwiftUI
import VPNGuardCore

/// Servers: one test server for ping and speed. Click a row to use it.
struct QualityServersPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quality: QualityMonitor
    @State private var provider: TestProvider?
    @State private var search = ""

    private enum W {
        static let radio: CGFloat = 20, provider: CGFloat = 124, ping: CGFloat = 76, abilities: CGFloat = 110
    }

    var body: some View {
        let rows = servers
        let fastest = rows.first.flatMap { quality.serverTimes[$0.id] ?? nil } != nil && provider == nil && search.isEmpty
            ? rows.first?.id : nil
        VStack(alignment: .leading, spacing: 0) {
            currentCard
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("All servers").font(.system(size: 13, weight: .semibold))
                Text(measuredText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                if quality.measuringServers { ProgressView().controlSize(.small) }
                Button("Measure Again") { quality.measureServers() }
                    .buttonStyle(CardButtonStyle())
                    .disabled(quality.measuringServers || model.qualityContext?.via == nil)
            }
            .padding(.horizontal, 4)
            .padding(.top, 22)
            .padding(.bottom, 10)
            HStack(spacing: 10) {
                Picker("Provider", selection: $provider) {
                    Text("All").tag(TestProvider?.none)
                    ForEach(TestProvider.allCases, id: \.self) { Text($0.title).tag(TestProvider?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("City or region", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 9)
                .frame(width: 168, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
            }
            .padding(.bottom, 10)
            SettingsCard {
                HStack(spacing: 8) {
                    Color.clear.frame(width: W.radio, height: 1)
                    Cell(text: "Provider", width: W.provider, weight: .semibold, color: .secondary, size: 11.5)
                    Cell(text: "Where", weight: .semibold, color: .secondary, size: 11.5)
                    Cell(text: "Ping", width: W.ping, weight: .semibold, color: .secondary, size: 11.5)
                    Cell(text: "Can test", width: W.abilities, weight: .semibold, color: .secondary, size: 11.5)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { s in
                            RowDivider(leading: 0)
                            row(s, fastest: s.id == fastest)
                        }
                    }
                }
                .frame(height: min(CGFloat(rows.count), 9) * 33 + 1)
                .scrollBounceBehavior(.basedOnSize)
                RowDivider(leading: 0)
                Text(rows.isEmpty ? "No server matches. Try another city or provider."
                     : (rows.count > 9 ? "\(rows.count) servers. Scroll, filter or search." : "\(rows.count) server\(rows.count == 1 ? "" : "s")."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 32)
            }
            Text("Click a server to use it. AWS, Google Cloud and DigitalOcean can only measure ping: with one of them, speed tests use Cloudflare. Results are kept for each server, so the numbers always compare like with like.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 10)
        }
    }

    private var currentCard: some View {
        let s = quality.server
        let measured = quality.serverTimes[s.id] ?? nil
        let ms = measured ?? quality.recentStats()?.median
        return HStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Palette.tile))
            VStack(alignment: .leading, spacing: 3) {
                Text(s.longTitle).font(.system(size: 17, weight: .semibold))
                Text(s.canTestSpeed ? "Your test server. Pings and speed tests go here."
                                    : "Your test server. Pings go here; speed tests use Cloudflare.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(ms.map { "\(Int($0.rounded()))" } ?? "–").font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    if ms != nil { Text("ms").font(.system(size: 13)).foregroundStyle(.secondary) }
                }
                Text(s.canTestSpeed ? s.abilities : "Ping · speed via Cloudflare").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }

    private var measuredText: String {
        let count = "\(TestServers.all.count)"
        if quality.measuringServers { return "\(count) · measuring…" }
        guard let m = quality.serversMeasured else {
            return model.qualityContext?.via == nil ? "\(count) · nothing can go out here to measure them" : "\(count) · not measured yet"
        }
        let when = Date().timeIntervalSince(m.at) < 90 ? "just now" : m.at.formatted(date: .omitted, time: .shortened)
        let how = m.via == QualityVia.noVPN ? "without VPN" : "through \(m.via)"
        return "\(count) · measured \(when) \(how), fastest first"
    }

    /// Filtered by provider and search, fastest first; not measured or no answer last.
    private var servers: [TestServer] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return TestServers.all
            .filter { provider == nil || $0.provider == provider }
            .filter { q.isEmpty || $0.city.lowercased().contains(q) || ($0.code ?? "").lowercased().contains(q)
                || $0.provider.title.lowercased().contains(q) }
            .sorted { a, b in
                let ta = quality.serverTimes[a.id] ?? nil, tb = quality.serverTimes[b.id] ?? nil
                switch (ta, tb) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.id == TestServers.defaultID || (b.id != TestServers.defaultID && a.title < b.title)
                }
            }
    }

    private func row(_ s: TestServer, fastest: Bool) -> some View {
        let measured = quality.serverTimes[s.id]
        let ms: String = measured == nil ? (quality.measuringServers ? "…" : "–") : (measured!.map { "\(Int($0.rounded())) ms" } ?? "no answer")
        let inUse = s.id == quality.serverID
        return Button { quality.serverID = s.id } label: {
            HStack(spacing: 8) {
                Image(systemName: inUse ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(inUse ? Tone.blue.fill : Color.secondary.opacity(0.6))
                    .frame(width: W.radio)
                Cell(text: s.provider.title, width: W.provider, weight: .medium)
                HStack(spacing: 5) {
                    Text(s.provider == .cloudflare && s.city == "Nearest" ? "Nearest city" : s.city)
                        .font(.system(size: 12.5)).lineLimit(1)
                    if let code = s.code { Text(code).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    if fastest { Pill(text: "Fastest", tone: .green) }
                    if inUse { Text("In use").font(.system(size: 11, weight: .medium)).foregroundStyle(Tone.blue.text) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Cell(text: ms, width: W.ping, weight: fastest ? .semibold : .regular,
                     color: measured == nil || measured! == nil ? .secondary : .primary)
                Cell(text: s.abilities, width: W.abilities, color: s.canTestSpeed ? .primary : .secondary, size: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(inUse ? Tone.blue.fill.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(quality.run != nil)
        .accessibilityAddTraits(inUse ? .isSelected : [])
    }
}

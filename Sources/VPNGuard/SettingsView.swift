import SwiftUI
import VPNGuardCore

/// Settings window: title bar with icon tabs on top (design canvas, "menu on top"), page below.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsTopBar()
            ScrollView {
                Group {
                    switch model.settingsPane {
                    case .general: GeneralPage()
                    case .networks: NetworksPage()
                    case .vpn: VPNPage()
                    case .about: AboutPage()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 700, height: 640)
        .background(Palette.window)
        .ignoresSafeArea(edges: .top)
        .onAppear {
            model.reloadVPNServices()
            model.refresh()
        }
    }
}

// MARK: - Top bar

private struct SettingsTopBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(model.settingsPane.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                HStack {
                    Spacer()
                    statusChip
                }
                .padding(.trailing, 12)
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            HStack(spacing: 6) {
                ForEach(SettingsPane.allCases) { pane in tab(pane) }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.header)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }

    private var statusChip: some View {
        let look = model.look
        return HStack(spacing: 6) {
            Circle().fill(look.tone.fill).frame(width: 6, height: 6)
            Text(look.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(look.tone.text)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(look.tone.fill.opacity(0.14)))
        .accessibilityElement(children: .combine)
    }

    private func tab(_ pane: SettingsPane) -> some View {
        let selected = model.settingsPane == pane
        return Button { model.settingsPane = pane } label: {
            VStack(spacing: 4) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(pane.color))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                Text(pane.title)
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

// MARK: - Header card (top of each page)

private struct HeaderCard<Leading: View, Trailing: View>: View {
    let title: String
    let detail: Text
    var glow: Tone? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                detail.font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(alignment: .topLeading) {
            if let glow {
                StateGlow(tone: glow, width: 240, height: 200).offset(x: -70, y: -80)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

/// Shown at the top of a page while the helper is not ready.
private struct HelperNeededCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HeaderCard(title: model.look.title, detail: Text(model.look.subtitle), glow: .red) {
            StatusOrb(glyph: .bang, tone: .red, size: 42)
        } trailing: {
            Button(model.look.primary?.title ?? "Install Helper…") { model.installHelper() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.helperReady {
                protectionCard
            } else {
                HelperNeededCard()
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Start")
                SettingsCard {
                    ToggleRow(title: "Open VPN Guard at login",
                              isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                }
                Text("The firewall keeps working even when the app is closed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Menu bar icon")
                SettingsCard(padding: 14) { IconLegend() }
            }
        }
    }

    private var protectionCard: some View {
        let on = model.protectionOn
        let places = (model.status?.config.trusted.map(\.name) ?? []).uniqued()
        let where_ = places.isEmpty ? "Outside your trusted networks" : "Outside \(places.prefix(3).joined(separator: " and "))"
        return HStack(spacing: 16) {
            StatusOrb(glyph: on ? .lock : .dashed, tone: on ? .green : .gray, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(on ? "Protection is on" : "Protection is off").font(.system(size: 17, weight: .semibold))
                Text(on ? "\(where_), only the VPN can reach the internet. If the VPN is off, nothing gets out."
                        : "Turn it on to block the internet outside your trusted networks, except through the VPN.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Protection", isOn: Binding(get: { model.protectionOn }, set: { model.setProtection($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Tone.green.fill)
        }
        .padding(18)
        .background(alignment: .topLeading) {
            StateGlow(tone: on ? .green : .gray, width: 260, height: 220).offset(x: -70, y: -80).opacity(0.55)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.cardFill))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.cardStroke))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

private struct IconLegend: View {
    private let items: [(GlyphKind, String)] = [
        (.lock, "Protected"), (.check, "Trusted"), (.dots, "Connecting"),
        (.cross, "Blocked"), (.pause, "Paused"), (.dashed, "Off"), (.bang, "Attention"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                VStack(spacing: 7) {
                    GuardGlyph(kind: items[i].0, color: .primary, lineWidth: 1.9)
                        .frame(width: 17, height: 17)
                        .frame(width: 40, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                    Text(items[i].1).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(items[i].1)
            }
        }
    }
}

// MARK: - Networks

private struct NetworksPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var selected: UUID?
    @State private var details: TrustedNetwork?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.helperReady {
                hereCards
            } else {
                HelperNeededCard()
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Trusted networks", trailing: "Normal internet here, no VPN needed")
                SettingsCard {
                    let trusted = model.status?.config.trusted ?? []
                    if trusted.isEmpty {
                        Text("None yet. Trust your home and office when you are there.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).frame(height: 44)
                    }
                    ForEach(Array(trusted.enumerated()), id: \.element.id) { index, t in
                        if index > 0 { RowDivider(leading: 42) }
                        trustedRow(t)
                    }
                    ListBar(add: model.canTrustCurrent ? { model.trustCurrentNetwork() } : nil,
                            remove: selectedNetwork.map { t in { model.untrust(t) } },
                            addHelp: "Trust the network you are on",
                            removeHelp: "Remove the selected network",
                            caption: "Known by the router's hardware address, not the Wi‑Fi name")
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Everywhere else")
                SettingsCard {
                    ToggleRow(title: "Only the VPN can reach the internet", detail: "If the VPN is off, nothing gets out.",
                              isOn: Binding(get: { model.protectionOn }, set: { model.setProtection($0) }))
                }
            }
            .disabled(!model.helperReady)
        }
        .sheet(item: $details) { t in
            TrustedNetworkSheet(network: t).environmentObject(model)
        }
    }

    private var selectedNetwork: TrustedNetwork? {
        model.status?.config.trusted.first { $0.id == selected }
    }

    @ViewBuilder private var hereCards: some View {
        let links = model.status?.links ?? []
        if links.isEmpty {
            HeaderCard(title: "No network", detail: Text("Join a network. VPN Guard checks it right away.")) {
                IconTile(symbol: "wifi.slash", tone: nil, size: 42)
            } trailing: { EmptyView() }
        }
        ForEach(links, id: \.interface) { link in
            let trusted = link.trustedName != nil
            let hotspot = link.routerIP == "172.20.10.1"
            HeaderCard(title: link.trustedName ?? (hotspot ? "iPhone hotspot" : link.label),
                       detail: Text("\(link.label) · router \(link.routerIP) · ")
                        + Text(trusted ? "Trusted" : "Not trusted").foregroundColor(trusted ? Tone.blue.text : Tone.orange.text).fontWeight(.medium)) {
                IconTile(symbol: trusted ? AppModel.symbol(forTrustedName: link.trustedName ?? "") : AppModel.symbol(for: link, hotspot: hotspot),
                         tone: trusted ? .blue : .orange, size: 42)
            } trailing: {
                if !trusted {
                    Button("Trust This Network…") { model.trustCurrentNetwork() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canTrustCurrent)
                }
            }
        }
    }

    private func trustedRow(_ t: TrustedNetwork) -> some View {
        let isSelected = selected == t.id
        return HStack(spacing: 10) {
            Image(systemName: AppModel.symbol(forTrustedName: t.name))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tone.blue.text)
                .frame(width: 18)
            Text(t.name).font(.system(size: 13, weight: .semibold))
            Text(t.routerIP ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.isCurrent(t) {
                DotStatus(text: "Here now", tone: .green)
            } else {
                Text(t.addedAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            InfoButton(label: "Details for \(t.name)") { details = t }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected ? nil : t.id }
        .contextMenu {
            Button("Rename…") { model.rename(t) }
            Button("Remove", role: .destructive) { model.untrust(t) }
        }
    }
}

// MARK: - VPN

private struct VPNPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var addingVPN = false
    @State private var prefill: VPNProfileDraft?
    @State private var details: VPNService?
    @State private var showingServers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.helperReady {
                currentCard
            } else {
                HelperNeededCard()
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Your VPNs", trailing: "The one with ✓ is used where you don't trust the network")
                SettingsCard {
                    if model.vpnServices.isEmpty {
                        Text("No VPN yet. Press + to add one: WireGuard is built in.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).frame(height: 44)
                    }
                    ForEach(Array(model.vpnServices.enumerated()), id: \.element.id) { index, v in
                        if index > 0 { RowDivider(leading: 66) }
                        vpnRow(v)
                    }
                    ListBar(add: model.helperReady ? { prefill = nil; addingVPN = true } : nil,
                            remove: removableSelection.map { v in { model.removeWireGuard(v) } },
                            addHelp: "Add a VPN",
                            removeHelp: "Remove the chosen WireGuard VPN (remove macOS VPNs in System Settings)",
                            caption: "WireGuard is built in · L2TP and IKEv2 use macOS")
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Automatic")
                SettingsCard {
                    ToggleRow(title: "Connect by itself on untrusted networks", isOn: $model.autoConnect)
                    RowDivider()
                    ToggleRow(title: "Disconnect when I join a trusted network", isOn: $model.autoDisconnect)
                }
                HStack {
                    Text("The VPN server is let through the firewall for you.")
                    Spacer()
                    Button("Allowed servers…") { showingServers = true }
                        .buttonStyle(.link)
                        .disabled(!model.helperReady)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.top, 8)
            }
        }
        .sheet(isPresented: $addingVPN) {
            AddVPNFlow(prefill: prefill).environmentObject(model)
        }
        .sheet(item: $details) { v in
            VPNDetailSheet(serviceID: v.id) { draft in
                details = nil
                prefill = draft
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { addingVPN = true }
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $showingServers) {
            AllowedServersSheet().environmentObject(model)
        }
    }

    private var removableSelection: VPNService? {
        guard let v = model.selectedVPN, v.engine == .wireGuard else { return nil }
        return v
    }

    @ViewBuilder private var currentCard: some View {
        if let v = model.selectedVPN {
            let state = model.vpnState
            let tone: Tone = state == .connected ? .green : (state == .connecting ? .orange : .gray)
            let glyph: GlyphKind = state == .connected ? .lock : (state == .connecting ? .dots : .empty)
            let stateText = state == .connected ? "Connected" : state.text
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HeaderCard(title: v.name,
                           detail: Text(stateText).foregroundColor(tone == .gray ? nil : tone.text).fontWeight(.medium)
                            + Text(currentDetail(v, now: context.date))) {
                    StatusOrb(glyph: glyph, tone: tone, size: 42, pulsing: state == .connecting)
                } trailing: {
                    if state.isUp {
                        Button("Disconnect") { model.disconnectVPN() }
                    } else {
                        Button("Connect") { model.connectVPN() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        } else {
            HeaderCard(title: "No VPN chosen", detail: Text("Pick one below, or press + to add one.")) {
                StatusOrb(glyph: .empty, tone: .gray, size: 42)
            } trailing: { EmptyView() }
        }
    }

    private func currentDetail(_ v: VPNService, now: Date) -> String {
        var parts: [String] = []
        if model.vpnState == .connected, let since = model.vpnConnectedSince {
            let d = AppModel.duration(now.timeIntervalSince(since))
            if d != "just now" { parts.append(d) }
        }
        if v.engine == .wireGuard, model.vpnState == .connected, let rt = model.wgRuntime {
            parts.append("↓ \(AppModel.bytes(rt.rxBytes)) ↑ \(AppModel.bytes(rt.txBytes))")
        }
        parts.append(v.typeLabel)
        if let server = v.remoteAddress, !server.isEmpty { parts.append(server) }
        return " · " + parts.joined(separator: " · ")
    }

    private func vpnRow(_ v: VPNService) -> some View {
        let chosen = model.selectedVPNID == v.id
        return HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Tone.green.text)
                .opacity(chosen ? 1 : 0)
                .frame(width: 16)
                .accessibilityHidden(!chosen)
            Group {
                if v.engine == .wireGuard {
                    TunnelGlyph()
                        .stroke(style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Tone.green.text)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: v.symbol).font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
            Text(v.name).font(.system(size: 13, weight: chosen ? .semibold : .medium)).lineLimit(1)
            Text(v.typeLabel).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if chosen && model.vpnState == .connected {
                DotStatus(text: "Connected", tone: .green)
            } else if chosen && model.vpnState == .connecting {
                DotStatus(text: "Connecting…", tone: .orange)
            } else if v.needsSendAllFix {
                Pill(text: "Needs a fix", tone: .orange)
            }
            InfoButton(label: "Details for \(v.name)") { details = v }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 44)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedVPNID = v.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Helper & About

private struct AboutPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HeaderCard(title: "VPN Guard",
                       detail: Text("Version \(VG.version) · Away from home and the office, only your VPN gets online.")) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .accessibilityHidden(true)
            } trailing: { EmptyView() }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Helper")
                SettingsCard {
                    ValueRow(title: "Status") { DotStatus(text: helperText, tone: helperTone) }
                    RowDivider()
                    ValueRow(title: "Firewall") {
                        Text(firewallText).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    RowDivider()
                    ValueRow(title: "WireGuard engine") {
                        Text(engineInstalled ? "Built in · ready" : "Missing · reinstall the helper")
                            .font(.system(size: 12))
                            .foregroundStyle(engineInstalled ? Color.secondary : Tone.orange.text)
                    }
                    VStack(spacing: 0) {
                        Rectangle().fill(Palette.separator).frame(height: 1)
                        HStack(spacing: 8) {
                            Button(model.helperNeedsUpdate ? "Update…" : (AppModel.helperInstalledOnDisk ? "Reinstall…" : "Install…")) {
                                model.installHelper()
                            }
                            Button("Show Log") { NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/vpnguard.log")) }
                            Spacer()
                            if AppModel.helperInstalledOnDisk {
                                Button("Uninstall…") { model.uninstallHelper() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Tone.red.text)
                                    .padding(.horizontal, 8)
                            }
                        }
                        .buttonStyle(CardButtonStyle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Palette.listBar)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeading(title: "Command line")
                SettingsCard(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(["vpnguard status", "vpnguard pause 5", "vpnguard wg up Home"], id: \.self) { cmd in
                            (Text("$ ").foregroundColor(.secondary) + Text(cmd))
                                .font(.system(size: 12).monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var engineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: "/Library/PrivilegedHelperTools/local.vpnguard.wireguard-go")
    }

    private var firewallText: String {
        guard let s = model.status else { return "–" }
        switch s.mode {
        case .locked: return "Locking now · only the VPN gets out"
        case .open: return s.config.enabled ? "Open · trusted network or paused" : "Open · protection is off"
        }
    }

    private var helperTone: Tone {
        switch model.helperState {
        case .ready: return .green
        case .outdated, .checking: return .orange
        case .notInstalled, .notResponding: return .red
        }
    }

    private var helperText: String {
        switch model.helperState {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .notResponding: return "Not responding"
        case .ready: return "Running · \(VG.version)"
        case .outdated(let v): return "Old version \(v)"
        }
    }
}

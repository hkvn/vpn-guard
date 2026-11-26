import SwiftUI
import VPNGuardCore

/// The window that opens from the menu bar icon.
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// After a few uses the "press and hold" hint is not needed any more.
    @AppStorage("orbUses") private var orbUses = 0

    var body: some View {
        let look = model.look
        VStack(spacing: 0) {
            header(look)

            if model.helperReady {
                VStack(spacing: 8) {
                    ForEach(model.networkCards) { card in
                        InfoCard(symbol: card.symbol, tone: card.trusted == true ? .blue : nil,
                                 title: card.title, detail: card.detail) {
                            if let trusted = card.trusted {
                                Pill(text: card.pill, tone: trusted ? .blue : .orange)
                            }
                        }
                    }
                    vpnCard
                }
                .padding(.horizontal, 12)
            }

            if let action = look.primary {
                Button(action.title) {
                    model.runPrimary(action, openSettings: openSettings)
                }
                .buttonStyle(PrimaryButtonStyle(tone: look.tone))
                .disabled(action == .connecting || model.busy)
                .padding(.horizontal, 12)
                .padding(.top, model.helperReady ? 12 : 0)
            }

            if model.helperReady {
                actions
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            } else {
                Spacer().frame(height: 16)
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .animation(.smooth(duration: 0.35), value: look)
        .onAppear { model.refresh() }
    }

    // MARK: Header

    private func header(_ look: StateLook) -> some View {
        VStack(spacing: 0) {
            ProtectionOrb(glyph: look.glyph, tone: look.tone, isOn: model.protectionOn,
                          toggle: model.helperReady ? { toggleFromOrb() } : nil)
            Text(look.title)
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
                .padding(.top, 2)
            Text(look.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 272)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
            if let until = model.pausedUntil {
                PauseProgress(until: until, length: model.pauseLength)
                    .padding(.top, 14)
            }
            if model.helperReady && orbUses < 3 {
                Label("Press and hold the shield to turn protection \(model.protectionOn ? "off" : "on")",
                      systemImage: "hand.tap")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            BreathingGlow(tone: look.tone, glyph: look.glyph, width: 340, height: 260)
                .offset(y: -90)
        }
        .clipped()
        .accessibilityElement(children: .contain)
    }

    /// Press-and-hold on the orb: same as the Protection switch (with its warnings).
    private func toggleFromOrb() {
        orbUses += 1
        model.setProtection(!model.protectionOn)
    }

    // MARK: Cards

    private var vpnCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            InfoCard(symbol: model.selectedVPN?.symbol ?? "globe",
                     tone: model.selectedVPN?.engine == .wireGuard ? .green : nil,
                     title: model.selectedVPN?.name ?? "No VPN chosen",
                     detail: model.vpnDetail(now: context.date)) {
                if model.selectedVPN != nil {
                    Toggle("VPN", isOn: Binding(
                        get: { model.vpnState.isUp },
                        set: { $0 ? model.connectVPN() : model.disconnectVPN() }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Tone.green.fill)
                    .accessibilityLabel("VPN connection")
                } else {
                    Button("Choose…") { openSettings(.vpn) }
                        .buttonStyle(SecondaryButtonStyle(height: 26, fullWidth: false))
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            if model.status?.reason == .trusted || model.mixedUsesTrusted {
                Button("Manage Networks…") { openSettings(.networks) }
            } else {
                Button("Trust This Network…") { model.trustCurrentNetwork() }
                    .disabled(!model.canTrustCurrent)
            }
            if model.isPaused {
                Button("+5 min") { model.extendPause(minutes: 5) }
            } else {
                Menu {
                    Button("5 minutes") { model.pause(minutes: 5) }
                    Button("15 minutes") { model.pause(minutes: 15) }
                    Button("1 hour") { model.pause(minutes: 60) }
                } label: {
                    HStack(spacing: 4) {
                        Text("Pause")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .disabled(!model.protectionOn)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Protection")
                .font(.system(size: 13, weight: .medium))
            Toggle("Protection", isOn: Binding(
                get: { model.protectionOn },
                set: { model.setProtection($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(Tone.green.fill)
            .disabled(!model.helperReady)
            Spacer()
            Button { openSettings(nil) } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("Quit VPN Guard")
            .accessibilityLabel("Quit VPN Guard")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(Palette.footer)
    }

    private func openSettings(_ pane: SettingsPane?) {
        if let pane { model.settingsPane = pane }
        MenuBarPanel.close()
        NSApp.activate()
        openWindow(id: "settings")
    }
}

/// Time left in a pause, with a thin bar.
struct PauseProgress: View {
    let until: Date
    let length: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, until.timeIntervalSince(context.date))
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(Tone.yellow.fill)
                            .frame(width: geo.size.width * min(1, left / max(length, left, 1)))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text("Until \(AppModel.time(until))")
                    Spacer()
                    Text("\(Int(left) / 60):\(String(format: "%02d", Int(left) % 60)) left")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(width: 220)
        }
    }
}

import SwiftUI
import VPNGuardCore

/// First-run window: install the helper, choose the VPN, trust this network, turn on.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var skippedTrust = false
    @State private var addingVPN = false

    var body: some View {
        HStack(spacing: 0) {
            hero
                .frame(width: 260)
                .frame(maxHeight: .infinity)
                .clipped()
                // Backgrounds reach under the hidden title bar, so the panel fills the window.
                .background(Color(light: NSColor(white: 0.96, alpha: 1), dark: NSColor(hex: 0x17191D)))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).ignoresSafeArea()
                }
            steps
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 22)
        }
        .frame(width: 720, height: 460)
        .sheet(isPresented: $addingVPN) {
            AddVPNFlow().environmentObject(model)
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            StatusOrb(glyph: .lock, tone: .green, size: 108)
                .background {
                    StateGlow(tone: .green, width: 380, height: 340)
                }
            Text("VPN Guard")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.4)
                .padding(.top, 22)
            Text("Away from home and the office, only your VPN gets online.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
                .padding(.top, 8)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up in three steps")
                .font(.system(size: 20, weight: .semibold))
                .tracking(-0.3)
            Text("Your internet keeps working until you turn protection on.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 18) {
                StepRow(number: 1, done: model.helperReady, title: "Install the helper",
                        detail: model.helperReady ? "It runs the macOS firewall for you. Done." : "It runs the macOS firewall for you. macOS asks for your password once.") {
                    if !model.helperReady {
                        Button("Install…") { model.installHelper() }
                            .buttonStyle(SecondaryButtonStyle(height: 28, fullWidth: false))
                    }
                }

                StepRow(number: 2, done: vpnReady, title: "Choose your VPN", detail: vpnCaption) {
                    HStack(spacing: 10) {
                        Picker("VPN", selection: $model.selectedVPNID) {
                            Text("Choose…").tag(String?.none)
                            ForEach(model.vpnServices) { v in
                                Text("\(v.name)  ·  \(v.kind)").tag(String?.some(v.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 250)
                        Button("New…") { addingVPN = true }
                            .buttonStyle(SecondaryButtonStyle(height: 24, fullWidth: false))
                    }
                    .disabled(!model.helperReady)
                }

                StepRow(number: 3, done: trustDone, title: "Trust your home and office", detail: trustCaption) {
                    if model.helperReady && !trustDone && !skippedTrust {
                        HStack(spacing: 8) {
                            Button("Trust This Network…") { model.trustCurrentNetwork() }
                                .buttonStyle(SecondaryButtonStyle(height: 28, fullWidth: false))
                                .disabled(!model.canTrustCurrent)
                            Button("Not now") { skippedTrust = true }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 24)

            Spacer(minLength: 12)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Later") {
                    model.completeOnboarding()
                    dismissWindow(id: "welcome")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                Button(model.protectionOn ? "Done" : "Turn On Protection") {
                    if !model.protectionOn { model.setProtection(true) }
                    model.completeOnboarding()
                    dismissWindow(id: "welcome")
                }
                .buttonStyle(PrimaryButtonStyle(tone: .green, height: 32))
                .frame(width: 180)
                .disabled(!model.helperReady || !vpnReady)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 16)
        }
    }

    private var vpnReady: Bool {
        model.selectedVPN != nil && !(model.status?.config.allowedIPs.isEmpty ?? true)
    }

    private var vpnCaption: String {
        guard let vpn = model.selectedVPN else { return "The VPN from System Settings to use on networks you don't trust." }
        let server = vpn.remoteAddress.map(GuardConfig.normalizeServer) ?? ""
        if let ips = model.status?.config.hostIPs[server], !ips.isEmpty {
            return "\(server) → \(ips.joined(separator: ", ")) is allowed through the firewall."
        }
        if Net.isIPv4(server), model.status?.config.allowedIPs.contains(server) == true {
            return "\(server) is allowed through the firewall."
        }
        return "Allowing \(server) through the firewall…"
    }

    private var trustDone: Bool {
        !(model.status?.config.trusted.isEmpty ?? true)
    }

    private var trustCaption: String {
        if let names = model.status?.config.trusted.map(\.name), !names.isEmpty {
            return "Trusted: \(names.joined(separator: ", ")). Add the other one when you are there."
        }
        if let link = model.status?.links.first {
            let hotspot = link.routerIP == "172.20.10.1"
            return "You are on \(hotspot ? "an iPhone hotspot" : link.label), router \(link.routerIP). Is this home or the office?"
        }
        return "When you are at home or the office, trust that network from the menu bar."
    }
}

private struct StepRow<Content: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if done {
                    Circle().fill(Tone.green.fill)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Palette.onFill)
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                    Text("\(number)").font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 26, height: 26)
            .animation(.spring(duration: 0.35), value: done)

            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                content()
                    .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

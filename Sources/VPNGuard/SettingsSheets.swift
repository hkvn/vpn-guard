import SwiftUI
import VPNGuardCore

/// Shared look for the small sheets: header, body, footer.
private struct SheetFrame<Content: View, Footer: View>: View {
    let symbol: String
    var tone: Tone? = nil
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, tone: tone, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)

            Rectangle().fill(Palette.separator).frame(height: 1)
            HStack(spacing: 10) { footer() }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 500)
        .background(Palette.sheet)
    }
}

// MARK: - VPN details

struct VPNDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let serviceID: String
    /// "Make a New Copy…" for a macOS VPN: hands a pre-filled form back to the VPN page.
    let makeCopy: (VPNProfileDraft) -> Void

    private var service: VPNService? { model.vpnServices.first { $0.id == serviceID } }
    private var chosen: Bool { model.selectedVPNID == serviceID }

    var body: some View {
        if let v = service {
            SheetFrame(symbol: v.symbol, tone: v.engine == .wireGuard ? .green : nil, title: v.name, subtitle: subtitle(v)) {
                if v.needsSendAllFix { fixCard(v) }
                SettingsCard {
                    if let server = v.remoteAddress, !server.isEmpty {
                        ValueRow(title: "Server") { mono(server) }
                        RowDivider()
                    }
                    if let account = v.account, !account.isEmpty {
                        ValueRow(title: "Account") { Text(account).foregroundStyle(.secondary) }
                        RowDivider()
                    }
                    if let t = model.tunnel(for: v) {
                        ValueRow(title: "Your address") { mono(t.addresses.joined(separator: ", ")) }
                        RowDivider()
                        ValueRow(title: "DNS") { mono(t.dns.isEmpty ? "–" : t.dns.joined(separator: ", ")) }
                        RowDivider()
                    }
                    ValueRow(title: "Allowed through the firewall") {
                        Label(v.isOtherApp ? "No (another app)" : (v.engine == .wireGuard ? "Yes" : "Yes, when chosen"),
                              systemImage: v.isOtherApp ? "minus" : "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(v.isOtherApp ? Color.secondary : Tone.green.text)
                    }
                    RowDivider()
                    ToggleRow(title: "Use on untrusted networks", isOn: Binding(
                        get: { chosen },
                        set: { model.selectedVPNID = $0 ? serviceID : nil }
                    ))
                }
                if let t = model.tunnel(for: v) { wireGuardKeys(t) }
            } footer: {
                if chosen {
                    if model.vpnState.isUp {
                        Button("Disconnect") { model.disconnectVPN() }
                    } else {
                        Button("Connect") { model.connectVPN() }
                    }
                }
                if v.engine == .wireGuard {
                    Button("Remove…") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.removeWireGuard(v) }
                    }
                    .foregroundStyle(Tone.red.text)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            SheetFrame(symbol: "questionmark", title: "VPN not found", subtitle: "It was removed.") {
                EmptyView()
            } footer: {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func subtitle(_ v: VPNService) -> String {
        let where_ = v.engine == .wireGuard ? "built in" : (v.isOtherApp ? "another app" : "VPN in macOS")
        let state = chosen ? model.vpnState.text : "Not in use"
        return "\(v.typeLabel) · \(where_) · \(state)"
    }

    private func mono(_ s: String) -> some View {
        Text(s).font(.system(size: 12).monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }

    private func fixCard(_ v: VPNService) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tone.orange.text)
            VStack(alignment: .leading, spacing: 4) {
                Text("“Send all traffic” is off").font(.system(size: 13, weight: .semibold))
                Text("Websites stay blocked even when this VPN is connected. Turn it on in System Settings (VPN → ⓘ → Options), or let VPN Guard make a new copy with the right setting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open VPN Settings") { AppModel.openVPNSettings() }
                        .buttonStyle(CardButtonStyle())
                    Button("Make a New Copy…") {
                        var d = VPNProfileDraft()
                        d.kind = v.typeLabel == "IKEv2" ? .ikev2 : .l2tp
                        d.name = "\(v.name) (VPN Guard)"
                        d.server = v.remoteAddress ?? ""
                        d.account = v.account ?? ""
                        makeCopy(d)
                    }
                    .buttonStyle(CardButtonStyle(prominent: true))
                }
                .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tone.orange.fill.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tone.orange.fill.opacity(0.35)))
    }

    private func wireGuardKeys(_ t: WireGuardTunnel) -> some View {
        SettingsCard {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your public key").font(.system(size: 12, weight: .semibold))
                    Text(t.publicKey).font(.system(size: 11.5).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Copy") { AppModel.copyToClipboard(t.publicKey) }.buttonStyle(CardButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            RowDivider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MikroTik command").font(.system(size: 12, weight: .semibold))
                    Text("Adds this Mac as a peer on the router.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { AppModel.copyToClipboard(t.mikrotikCommand()) }.buttonStyle(CardButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Trusted network details

struct TrustedNetworkSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let network: TrustedNetwork

    var body: some View {
        SheetFrame(symbol: AppModel.symbol(forTrustedName: network.name), tone: .blue, title: network.name,
                   subtitle: model.isCurrent(network) ? "Trusted · you are here now" : "Trusted network") {
            SettingsCard {
                ValueRow(title: "Router") {
                    Text(network.routerIP ?? "–").font(.system(size: 12).monospaced()).foregroundStyle(.secondary)
                }
                RowDivider()
                ValueRow(title: "Router hardware address") {
                    Text(network.routerMAC).font(.system(size: 12).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                RowDivider()
                ValueRow(title: "Added") {
                    Text(network.addedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("On this network the internet works normally, without the VPN. VPN Guard knows it by the router's hardware address, which is much harder to fake than a Wi‑Fi name.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        } footer: {
            Button("Rename…") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.rename(network) }
            }
            Button("Remove…") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.untrust(network) }
            }
            .foregroundStyle(Tone.red.text)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Allowed servers (advanced)

struct AllowedServersSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newServer = ""

    var body: some View {
        SheetFrame(symbol: "network.badge.shield.half.filled", title: "Allowed servers",
                   subtitle: "While blocked, only these may be reached outside the VPN") {
            let config = model.status?.config
            let servers = config?.serverHosts ?? []
            SettingsCard {
                if servers.isEmpty {
                    Text("None yet. VPN Guard adds your VPN's server for you.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).frame(height: 44)
                }
                ForEach(Array(servers.enumerated()), id: \.element) { index, server in
                    if index > 0 { RowDivider() }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server).font(.system(size: 12.5).monospaced())
                            if Net.isHostName(server) {
                                let ips = config?.hostIPs[server] ?? []
                                Text(ips.isEmpty ? "IP not known yet" : "→ \(ips.joined(separator: ", "))")
                                    .font(.system(size: 11).monospaced())
                                    .foregroundStyle(ips.isEmpty ? Tone.orange.text : Color.secondary)
                            }
                        }
                        Spacer()
                        if config?.vpnServers.contains(server) == true {
                            Button { model.removeVPNServer(server) } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Remove \(server)")
                        } else {
                            Text("WireGuard").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                }
            }
            HStack {
                TextField("Another server", text: $newServer, prompt: Text("IP or host name"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newServer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } footer: {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func add() {
        let value = newServer.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        model.addVPNServer(value)
        newServer = ""
    }
}

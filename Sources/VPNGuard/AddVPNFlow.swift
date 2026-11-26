import SwiftUI
import UniformTypeIdentifiers
import VPNGuardCore

/// "Add a VPN" sheet: choose the type, then WireGuard (built in) or an L2TP/IKEv2 macOS VPN,
/// then (macOS VPNs only) approve it in System Settings.
struct AddVPNFlow: View {
    enum Step: Equatable {
        case chooseType, wireGuard, macForm, approve(String)
    }

    enum Choice: Equatable {
        case wireGuard, l2tp, ikev2
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var choice: Choice
    @State private var draft: VPNProfileDraft

    init(start: Step = .chooseType, prefill: VPNProfileDraft? = nil) {
        _step = State(initialValue: prefill != nil ? .macForm : start)
        _choice = State(initialValue: prefill.map { $0.kind == .ikev2 ? .ikev2 : .l2tp } ?? .wireGuard)
        _draft = State(initialValue: prefill ?? VPNProfileDraft())
    }

    var body: some View {
        Group {
            switch step {
            case .chooseType:
                ChooseTypeStep(choice: $choice, cancel: { dismiss() }) {
                    switch choice {
                    case .wireGuard: step = .wireGuard
                    case .l2tp: draft.kind = .l2tp; step = .macForm
                    case .ikev2: draft.kind = .ikev2; step = .macForm
                    }
                }
            case .wireGuard:
                WireGuardStep(back: { step = .chooseType }, cancel: { dismiss() }, done: { dismiss() })
            case .macForm:
                MacVPNStep(draft: $draft, back: { step = .chooseType }, cancel: { dismiss() }) { name in
                    step = .approve(name)
                }
            case .approve(let name):
                ApproveStep(name: name) {
                    model.stopWaitingForVPN()
                    dismiss()
                }
            }
        }
        .frame(width: 560)
        .animation(.smooth(duration: 0.25), value: step)
        .onChange(of: model.pendingVPNName) { _, now in
            if case .approve = step, now == nil { dismiss() }
        }
    }
}

// MARK: - Shared parts

private struct SheetHeader: View {
    let symbol: String
    let tone: Tone?
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, tone: tone, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

private struct SheetFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                leading()
                Spacer()
                trailing()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

/// A row of a grouped card: label on the left, field on the right.
private struct FieldRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: () -> Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 140, alignment: .leading)
            field()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

private struct CardGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardBorder))
    }
}

private struct ProblemList: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { p in
                Label(p, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Tone.red.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1. Choose the type

private struct ChooseTypeStep: View {
    @Binding var choice: AddVPNFlow.Choice
    let cancel: () -> Void
    let next: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(symbol: "plus", tone: .green, title: "Add a VPN",
                        subtitle: "Everything runs inside VPN Guard. There is nothing else to install.")
            VStack(spacing: 10) {
                option(.wireGuard, symbol: IconTile.tunnelSymbol, title: "WireGuard", badge: "Recommended",
                       text: "Fast and stable, built into VPN Guard. Works with MikroTik RouterOS 7 and most new routers. No approval in System Settings.")
                option(.l2tp, symbol: "globe", title: "L2TP over IPSec", badge: nil,
                       text: "For routers that only have L2TP, like DrayTek or MikroTik QuickSet. Uses the VPN built into macOS; you approve it once.")
                option(.ikev2, symbol: "lock", title: "IKEv2", badge: nil,
                       text: "For IKEv2 servers, with a shared secret or a user and password. Uses the VPN built into macOS; you approve it once.")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            SheetFooter {
                EmptyView()
            } trailing: {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Continue", action: next).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func option(_ value: AddVPNFlow.Choice, symbol: String, title: String, badge: String?, text: String) -> some View {
        let selected = choice == value
        return Button { choice = value } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Tone.green.fill : Color.secondary)
                    .padding(.top, 2)
                IconTile(symbol: symbol, tone: value == .wireGuard ? .green : nil, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if let badge {
                            Text(badge.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.3)
                                .foregroundStyle(Tone.green.text)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Tone.green.fill.opacity(0.16)))
                        }
                    }
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Tone.green.fill.opacity(0.07) : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Tone.green.fill : Palette.cardBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 2a. WireGuard

private struct WireGuardStep: View {
    enum Tab: Hashable { case importFile, newKeys }

    @EnvironmentObject private var model: AppModel
    let back: () -> Void
    let cancel: () -> Void
    let done: () -> Void

    @State private var tab: Tab = .newKeys
    @State private var busy = false
    @State private var errorText: String?
    @State private var showProblems = false

    // Import
    @State private var parsed: WireGuardConf.Parsed?
    @State private var fileName = ""
    @State private var importName = ""
    @State private var importError: String?
    @State private var dropTargeted = false
    @State private var choosingFile = false

    // New keys
    @State private var privateKey = WireGuardKey.generatePrivate()
    @State private var name = ""
    @State private var endpoint = ""
    @State private var serverKey = ""
    @State private var address = "10.8.0.2/32"
    @State private var dns = "1.1.1.1"

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(symbol: IconTile.tunnelSymbol, tone: .green, title: "Add WireGuard VPN",
                        subtitle: "Built into VPN Guard. Your private key never leaves this Mac.")
            Picker("How to add", selection: $tab) {
                Text("Import a file").tag(Tab.importFile)
                Text("Create new keys").tag(Tab.newKeys)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            Group {
                switch tab {
                case .importFile: importTab
                case .newKeys: newKeysTab
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .frame(minHeight: 440, alignment: .top)

            SheetFooter {
                Button("Back", action: back)
            } trailing: {
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Add VPN", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (tab == .importFile && parsed == nil))
            }
        }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]) { result in
            if case .success(let url) = result { load(url) }
        }
    }

    // MARK: Import

    private var importTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a WireGuard .conf file here").font(.system(size: 13, weight: .semibold))
                Text("The file your router or VPN admin gave you.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Choose File…") { choosingFile = true }
                    Button("Paste") {
                        if let text = NSPasteboard.general.string(forType: .string) { read(text, fileName: "Pasted") }
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 28, fullWidth: false))
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(dropTargeted ? Tone.green.fill.opacity(0.08) : Color.primary.opacity(0.025)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTargeted ? Tone.green.fill : Color.primary.opacity(0.28),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in load(url) } }
                }
                return true
            }

            if let importError {
                ProblemList(problems: [importError])
            }

            if let parsed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Found in \(fileName)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    CardGroup {
                        FieldRow(label: "Name") { TextField("Name", text: $importName, prompt: Text("Home")) }
                        RowDivider()
                        valueRow("Server", parsed.tunnel.endpoint)
                        RowDivider()
                        valueRow("Your address", parsed.tunnel.addresses.joined(separator: ", "))
                        RowDivider()
                        valueRow("DNS", parsed.tunnel.dns.isEmpty ? "–" : parsed.tunnel.dns.joined(separator: ", "))
                        RowDivider()
                        HStack {
                            Text("Traffic").frame(width: 140, alignment: .leading)
                            Spacer()
                            if parsed.tunnel.isFullTunnel {
                                Label("All traffic goes through the VPN", systemImage: "checkmark")
                                    .foregroundStyle(Tone.green.text)
                            } else {
                                Label("Only some addresses use the VPN", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Tone.orange.text)
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                    if parsed.tunnel.dns.isEmpty {
                        ProblemList(problems: ["This file has no DNS server. Websites may not open while blocked. Add DNS = 1.1.1.1 to the file."])
                    }
                }
            }
            if let errorText { ProblemList(problems: [errorText]) }
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func load(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importError = "Cannot read \(url.lastPathComponent)."
            return
        }
        read(text, fileName: url.lastPathComponent)
    }

    private func read(_ text: String, fileName: String) {
        let suggested = fileName == "Pasted" ? "WireGuard" : (fileName as NSString).deletingPathExtension
        do {
            let result = try WireGuardConf.parse(text, name: suggested)
            parsed = result
            self.fileName = fileName
            importName = suggested
            importError = nil
        } catch {
            parsed = nil
            importError = error.localizedDescription
        }
    }

    // MARK: New keys

    private var publicKey: String { WireGuardKey.publicKey(fromPrivate: privateKey) ?? "" }

    private var newTunnel: WireGuardTunnel {
        WireGuardTunnel(name: name.trimmingCharacters(in: .whitespaces), publicKey: publicKey,
                        addresses: address.split(separator: ",").map { Net.withPrefix($0.trimmingCharacters(in: .whitespaces)) },
                        dns: dns.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init),
                        peerPublicKey: serverKey.trimmingCharacters(in: .whitespaces),
                        endpoint: endpoint.trimmingCharacters(in: .whitespaces))
    }

    private var newKeysTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardGroup {
                FieldRow(label: "Name") { TextField("Name", text: $name, prompt: Text("Home")) }
                RowDivider()
                FieldRow(label: "Server") { TextField("Server", text: $endpoint, prompt: Text("home.example.net:51820")) }
                RowDivider()
                FieldRow(label: "Server public key") { TextField("Server public key", text: $serverKey, prompt: Text("From the router, ends with =")) }
                RowDivider()
                FieldRow(label: "Your address") { TextField("Your address", text: $address, prompt: Text("10.8.0.2/32")) }
                RowDivider()
                FieldRow(label: "DNS") { TextField("DNS", text: $dns, prompt: Text("1.1.1.1")) }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Your public key").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tone.green.text)
                    Spacer()
                    Button("Copy") { AppModel.copyToClipboard(publicKey) }
                        .buttonStyle(SecondaryButtonStyle(height: 24, fullWidth: false))
                }
                Text(publicKey)
                    .font(.system(size: 12.5).monospaced())
                    .textSelection(.enabled)
                Text("VPN Guard made a new key pair. Give this public key to the router.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.green.fill.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.green.fill.opacity(0.30)))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("On your MikroTik (Terminal)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { AppModel.copyToClipboard(newTunnel.mikrotikCommand()) }
                        .buttonStyle(SecondaryButtonStyle(height: 24, fullWidth: false))
                }
                .padding(.leading, 4)
                Text(newTunnel.mikrotikCommand())
                    .font(.system(size: 11.5).monospaced())
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(light: NSColor(white: 0.97, alpha: 1), dark: NSColor(hex: 0x141416))))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardBorder))
            }

            if showProblems {
                ProblemList(problems: newTunnel.problems() + (errorText.map { [$0] } ?? []))
            }
        }
    }

    // MARK: Add

    private func add() {
        errorText = nil
        let tunnel: WireGuardTunnel
        let key: String
        let psk: String?
        switch tab {
        case .importFile:
            guard var t = parsed?.tunnel, let p = parsed else { return }
            t.name = importName.trimmingCharacters(in: .whitespaces)
            if let problem = t.problems().first { errorText = problem; return }
            tunnel = t
            key = p.privateKey
            psk = p.presharedKey
        case .newKeys:
            showProblems = true
            guard newTunnel.problems().isEmpty else { return }
            tunnel = newTunnel
            key = privateKey
            psk = nil
        }
        busy = true
        model.addWireGuard(tunnel, privateKey: key, presharedKey: psk) { error in
            busy = false
            if let error {
                errorText = error
                showProblems = true
            } else {
                done()
            }
        }
    }
}

// MARK: - 2b. L2TP / IKEv2 (macOS VPN)

private struct MacVPNStep: View {
    @EnvironmentObject private var model: AppModel
    @Binding var draft: VPNProfileDraft
    let back: () -> Void
    let cancel: () -> Void
    let created: (String) -> Void
    @State private var showProblems = false
    @State private var errorText: String?

    private var problems: [String] {
        var p = draft.problems()
        if model.vpnServices.contains(where: { $0.name == draft.cleanName }) {
            p.append("A VPN named \"\(draft.cleanName)\" already exists. Pick another name.")
        }
        return p
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(symbol: draft.kind == .ikev2 ? "lock" : "globe", tone: nil,
                        title: draft.kind == .ikev2 ? "Add IKEv2 VPN" : "Add L2TP VPN",
                        subtitle: "Uses the VPN built into macOS. All traffic goes through it.")
            VStack(alignment: .leading, spacing: 14) {
                CardGroup {
                    FieldRow(label: "Name") { TextField("Name", text: $draft.name, prompt: Text("Office VPN")) }
                    RowDivider()
                    FieldRow(label: "Server") { TextField("Server", text: $draft.server, prompt: Text("vpn.example.com")) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                    CardGroup {
                        FieldRow(label: "Account") {
                            TextField("Account", text: $draft.account, prompt: Text(draft.kind == .l2tp ? "Your VPN user" : "Optional"))
                        }
                        RowDivider()
                        FieldRow(label: "Password") {
                            SecureField("Password", text: $draft.password, prompt: Text("Empty = ask when connecting"))
                        }
                        RowDivider()
                        FieldRow(label: "Shared secret") {
                            SecureField("Shared secret", text: $draft.sharedSecret,
                                        prompt: Text(draft.kind == .l2tp ? "IPSec pre-shared key" : "Optional"))
                        }
                    }
                }
                if draft.kind == .ikev2 {
                    CardGroup {
                        FieldRow(label: "Remote ID") { TextField("Remote ID", text: $draft.remoteID, prompt: Text("Same as server")) }
                        RowDivider()
                        FieldRow(label: "Local ID") { TextField("Local ID", text: $draft.localID, prompt: Text("Optional")) }
                    }
                }
                CardGroup {
                    FieldRow(label: "DNS servers") { TextField("DNS servers", text: $draft.dnsServers, prompt: Text("Optional, e.g. 1.1.1.1")) }
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(Tone.blue.text)
                    Text("macOS keeps the password and secret in its keychain; VPN Guard does not store them. Next, macOS asks you to approve the new VPN once.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.blue.fill.opacity(0.10)))

                if showProblems && !problems.isEmpty { ProblemList(problems: problems) }
                if let errorText { ProblemList(problems: [errorText]) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            SheetFooter {
                Button("Back", action: back)
            } trailing: {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Create VPN", action: create).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func create() {
        showProblems = true
        errorText = nil
        guard problems.isEmpty else { return }
        do {
            try model.createVPN(draft)
            created(draft.cleanName)
        } catch {
            errorText = "Could not make the profile: \(error.localizedDescription)"
        }
    }
}

// MARK: - 3. Approve in System Settings

private struct ApproveStep: View {
    let name: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StatusOrb(glyph: .dots, tone: .blue, size: 64, pulsing: true)
                Text("Approve “\(name)” in System Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                Text("macOS asks you once before any app can add a VPN. This window closes by itself when you are done.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 5)
            }
            .padding(.top, 26)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) { StateGlow(tone: .blue, width: 380, height: 260).offset(y: -110) }
            .clipped()

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    step(done: true, number: 1, "System Settings is open at Device Management.")
                    step(done: false, number: 2, "Double-click the profile below.")
                    step(done: false, number: 3, "Click Install, then type your Mac password.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardBorder))

                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: 0x636366)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("VPN Guard: \(name)").font(.system(size: 13, weight: .semibold))
                        Text("1 setting · VPN").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("in System Settings").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.blue.fill.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tone.blue.fill.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)

            SheetFooter {
                ProgressView().controlSize(.small)
                Text("Waiting for the VPN…").font(.system(size: 12)).foregroundStyle(.secondary)
            } trailing: {
                Button("Open System Settings") { AppModel.openProfilesSettings() }
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
        }
    }

    private func step(done: Bool, number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if done {
                    Circle().fill(Tone.green.fill)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Palette.onFill)
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2)
                    Text("\(number)").font(.system(size: 11, weight: .bold))
                }
            }
            .frame(width: 20, height: 20)
            Text(text).font(.system(size: 13))
        }
    }
}

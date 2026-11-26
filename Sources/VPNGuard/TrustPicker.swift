import AppKit
import SwiftUI
import VPNGuardCore

/// "Trust which network?": tick the networks to trust. Used when the Mac is on several networks, or
/// on a phone hotspot (which goes everywhere with the phone, so trusting it is risky).
/// Design: canvas artboard "Trust which network? (pick, hotspot warning)".
@MainActor
final class TrustPickerModel: ObservableObject {
    struct Row: Identifiable {
        let id: String          // router hardware address
        let title: String
        let detail: String
        let symbol: String
        let hotspot: Bool
    }

    let rows: [Row]
    @Published var ticked: Set<String>
    @Published var name = ""

    init(candidates: [NetworkLink], primaryInterface: String?) {
        rows = candidates.compactMap { link in
            guard let mac = link.routerMAC.flatMap(Net.normalizeMAC) else { return nil }
            let hotspot = TrustPick.isPhoneHotspot(link)
            let used = link.interface == primaryInterface && candidates.count > 1
            return Row(id: mac, title: link.label,
                       detail: "Router \(link.routerIP)\(used ? " · used by your Mac now" : "")",
                       symbol: AppModel.symbol(for: link, hotspot: hotspot), hotspot: hotspot)
        }
        ticked = TrustPick.defaultTicks(candidates, primaryInterface: primaryInterface)
    }

    var intro: String {
        let start = rows.count > 1 ? "Your Mac is on \(rows.count) networks. On a trusted one" : "On a trusted network"
        return "\(start) the internet works without the VPN. VPN Guard knows it by its router."
    }

    /// Says what will happen: "Trust Wi‑Fi", "Trust 2 Networks".
    var buttonTitle: String {
        let chosen = rows.filter { ticked.contains($0.id) }
        switch chosen.count {
        case 0: return "Trust"
        case 1: return "Trust \(chosen[0].title)"
        default: return "Trust \(chosen.count) Networks"
        }
    }

    var cleanName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "Trusted network" : n
    }

    func binding(for row: Row) -> Binding<Bool> {
        Binding(get: { self.ticked.contains(row.id) },
                set: { on in if on { self.ticked.insert(row.id) } else { self.ticked.remove(row.id) } })
    }
}

struct TrustPickerView: View {
    @ObservedObject var model: TrustPickerModel
    var onCancel: () -> Void = {}
    var onTrust: () -> Void = {}
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tone.blue.fill))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trust which network?")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.intro)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Networks you are on")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle().fill(Palette.separator).frame(height: 1).padding(.leading, 41)
                        }
                        rowView(row)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.cardStroke))
            }

            HStack(spacing: 10) {
                Text("Name")
                    .font(.system(size: 13))
                    .frame(width: 44, alignment: .leading)
                TextField("Office, Home…", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.buttonTitle, action: onTrust)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.ticked.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
        .frame(width: 448)
        .background(Palette.window)
        .onAppear { nameFocused = true }
    }

    @ViewBuilder
    private func rowView(_ row: TrustPickerModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: model.binding(for: row)) {
                HStack(spacing: 11) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.title).font(.system(size: 13, weight: .semibold))
                            if row.hotspot { Pill(text: "Phone hotspot", tone: .orange) }
                        }
                        Text(row.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)

            if row.hotspot {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    Text("A phone hotspot goes everywhere with you. If you trust it, the internet works without the VPN wherever you use this phone.")
                        .font(.system(size: 12))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Tone.orange.text)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tone.orange.fill.opacity(0.12)))
                .padding(.leading, 41)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

/// Shows the picker as a small modal window over everything (the menu bar panel closes first).
@MainActor
enum TrustPickerPresenter {
    /// True when the user pressed Trust.
    static func run(_ model: TrustPickerModel) -> Bool {
        MenuBarPanel.close()
        NSApp.activate()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 448, height: 320),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        var trusted = false
        let view = TrustPickerView(model: model,
                                   onCancel: { NSApp.stopModal() },
                                   onTrust: { trusted = true; NSApp.stopModal() })
            .ignoresSafeArea()
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return trusted
    }
}

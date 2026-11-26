import AppKit
import SwiftUI
import VPNGuardCore

/// `VPNGuard --render-previews <folder>` draws every screen with made-up data to PNG files and exits.
/// Used to check the design without a running helper or screen recording.
enum PreviewRenderer {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        OrbAnimation.live = false   // bitmaps do not include Core Animation layers

        let looks: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
        for (name, appearance) in looks {
            for scenario in AppModel.PreviewScenario.allCases {
                let model = AppModel(preview: scenario)
                let view = PopoverView()
                    .environmentObject(model)
                    .background(PanelBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                render(view, appearance: appearance, to: dir.appendingPathComponent("popover-\(scenario.rawValue)-\(name).png"))
            }
            for pane in SettingsPane.allCases {
                let model = AppModel(preview: .protected)
                model.settingsPane = pane
                let view = SettingsView().environmentObject(model)
                render(view, appearance: appearance, to: dir.appendingPathComponent("settings-\(pane.rawValue)-\(name).png"))
            }
            // Networks with two networks at once (Office over cable, in use, and Wi-Fi).
            let twoModel = AppModel(preview: .officeTwo)
            twoModel.settingsPane = .networks
            render(SettingsView().environmentObject(twoModel), appearance: appearance,
                   to: dir.appendingPathComponent("settings-networks-two-\(name).png"))
            // VPN list with a WireGuard tunnel that only carries the office network.
            let partialModel = AppModel(preview: .partial)
            partialModel.settingsPane = .vpn
            render(SettingsView().environmentObject(partialModel), appearance: appearance,
                   to: dir.appendingPathComponent("settings-vpn-partial-\(name).png"))
            // The chosen VPN was refused: red label in the list; and the same with a backup VPN in use.
            for scenario in [AppModel.PreviewScenario.failed, .backup] {
                let m = AppModel(preview: scenario)
                m.settingsPane = .vpn
                render(SettingsView().environmentObject(m), appearance: appearance,
                       to: dir.appendingPathComponent("settings-vpn-\(scenario.rawValue)-\(name).png"))
            }
            let failedModel = AppModel(preview: .failed)
            render(VPNDetailSheet(serviceID: "preview") { _ in }.environmentObject(failedModel), appearance: appearance,
                   to: dir.appendingPathComponent("sheet-vpn-detail-failed-\(name).png"))
            // Protection test: no leaks, a leak, and a trusted network.
            let wifi = LeakProbe(interface: "en0", label: "Wi-Fi", internetGotOut: false, dnsGotOut: false, ipv6GotOut: nil)
            var leaky = wifi
            leaky.internetGotOut = true
            let tests: [(String, LeakReport?)] = [
                ("pass", LeakTest.report(rulesActive: true, probes: [wifi], vpnName: "Office VPN", vpnConnected: true, viaVPNWorks: true)),
                ("leak", LeakTest.report(rulesActive: true, probes: [leaky], vpnName: "Office VPN", vpnConnected: true, viaVPNWorks: true)),
                ("trusted", LeakTest.withoutProbes(reason: .trusted, trustedNames: "Office")),
            ]
            for (label, report) in tests {
                render(ProtectionTestSheet(preset: report).environmentObject(failedModel), appearance: appearance,
                       to: dir.appendingPathComponent("sheet-protection-test-\(label)-\(name).png"))
            }
            // General with the Color menu bar icon style chosen.
            let colorModel = AppModel(preview: .protected)
            colorModel.settingsPane = .general
            colorModel.menuBarIconStyle = .color
            render(SettingsView().environmentObject(colorModel), appearance: appearance,
                   to: dir.appendingPathComponent("settings-general-color-\(name).png"))
            // General with "Open at login" off: the warning.
            let noLoginModel = AppModel(preview: .protected)
            noLoginModel.settingsPane = .general
            noLoginModel.previewLaunchAtLogin = false
            render(SettingsView().environmentObject(noLoginModel), appearance: appearance,
                   to: dir.appendingPathComponent("settings-general-login-off-\(name).png"))
            // The real menu bar images, both styles, on a dark and a light menu bar.
            let kinds: [GlyphKind] = [.lock, .check, .dots, .cross, .pause, .dashed, .bang]
            let strip = VStack(spacing: 8) {
                ForEach(MenuBarIconStyle.allCases) { style in
                    HStack(spacing: 8) {
                        ForEach([true, false], id: \.self) { darkBar in
                            HStack(spacing: 14) {
                                ForEach(kinds.indices, id: \.self) { i in
                                    Image(nsImage: GlyphRenderer.menuBarImage(kinds[i], description: "", style: style))
                                        .renderingMode(style == .color ? .original : .template)
                                        .foregroundStyle(darkBar ? Color.white : Color.black)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(darkBar ? Color(hex: 0x26282E) : Color(hex: 0xE8E8EC))
                        }
                    }
                }
            }
            .padding(10)
            render(strip, appearance: appearance, to: dir.appendingPathComponent("menubar-icons-\(name).png"))
            let steps: [(String, AddVPNFlow.Step)] = [("type", .chooseType), ("wireguard", .wireGuard),
                                                     ("l2tp", .macForm), ("approve", .approve("Branch Office"))]
            for (label, step) in steps {
                let add = AddVPNFlow(start: step).environmentObject(AppModel(preview: .protected))
                    .background(Color(nsColor: .windowBackgroundColor))
                render(add, appearance: appearance, to: dir.appendingPathComponent("add-vpn-\(label)-\(name).png"))
            }
            let wgSettings = SettingsView().environmentObject({ () -> AppModel in
                let m = AppModel(preview: .wireguard)
                m.settingsPane = .vpn
                return m
            }())
            render(wgSettings, appearance: appearance, to: dir.appendingPathComponent("settings-vpn-wireguard-\(name).png"))
            let wgModel = AppModel(preview: .wireguard)
            let sheets: [(String, AnyView)] = [
                ("vpn-detail-fix", AnyView(VPNDetailSheet(serviceID: "preview-2") { _ in }.environmentObject(wgModel))),
                ("vpn-detail-wireguard", AnyView(VPNDetailSheet(serviceID: wgModel.selectedVPNID ?? "") { _ in }.environmentObject(wgModel))),
                ("allowed-servers", AnyView(AllowedServersSheet().environmentObject(wgModel))),
            ]
            for (label, sheet) in sheets {
                render(sheet, appearance: appearance, to: dir.appendingPathComponent("sheet-\(label)-\(name).png"))
            }
            // "Trust which network?": office Wi-Fi (used by the Mac) + iPhone over USB.
            let pick = TrustPickerModel(candidates: [
                NetworkLink(interface: "en0", displayName: "Wi-Fi", address: "192.168.88.23",
                            routerIP: "192.168.88.1", routerMAC: "48:8f:5a:0b:11:20"),
                NetworkLink(interface: "en7", displayName: "iPhone USB", address: "172.20.10.2",
                            routerIP: "172.20.10.1", routerMAC: "9e:4a:01:7c:22:b5"),
            ], primaryInterface: "en0")
            pick.name = "Office"
            render(TrustPickerView(model: pick), appearance: appearance, to: dir.appendingPathComponent("trust-picker-\(name).png"))

            let onboarding = OnboardingView().environmentObject(AppModel(preview: .blocked))
                .background(Color(nsColor: .windowBackgroundColor))
            render(onboarding, appearance: appearance, to: dir.appendingPathComponent("welcome-\(name).png"))
        }
        print("Rendered previews to \(dir.path)")
        exit(0)
    }

    @MainActor
    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        // Views that size themselves after measuring (Settings follows its page height).
        let measured = hosting.fittingSize
        if abs(measured.height - size.height) > 0.5 || abs(measured.width - size.width) > 0.5 {
            hosting.frame = NSRect(origin: .zero, size: measured)
            window.setContentSize(measured)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }
}

/// Stands in for the menu bar window's material in previews.
private struct PanelBackground: View {
    var body: some View {
        Color(light: NSColor(hex: 0xF2F2F4), dark: NSColor(hex: 0x262629))
    }
}

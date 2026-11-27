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
            // Network Quality: the four tabs and the Monitor states, with made-up numbers.
            for (label, make) in QualityPreview.screens() {
                render(make(), appearance: appearance, to: dir.appendingPathComponent("quality-\(label)-\(name).png"))
            }
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

/// Made-up Network Quality data for `--render-previews` (example names only).
@MainActor
enum QualityPreview {
    static let vpns = [
        VPNService(id: "preview", name: "Office VPN", kind: "L2TP", remoteAddress: "vpn.example.com", sendsAllTraffic: true),
        VPNService(id: "preview-home", name: "Home VPN", kind: "IKEv2", remoteAddress: "home.example.com", sendsAllTraffic: true),
        VPNService(id: "preview-travel", name: "Travel VPN", kind: "L2TP", remoteAddress: "198.51.100.30", sendsAllTraffic: true),
        VPNService(id: "preview-2", name: "Branch Office", kind: "L2TP", remoteAddress: "203.0.113.10", sendsAllTraffic: false,
                   account: "vpn"),
    ]

    static func model(_ scenario: AppModel.PreviewScenario) -> AppModel {
        let m = AppModel(preview: scenario)
        m.previewSetMacVPNs(vpns)
        m.quality.model = m
        return m
    }

    static func view(_ m: AppModel, tab: QualityTab) -> AnyView {
        m.quality.tab = tab
        return AnyView(QualityView().environmentObject(m).environmentObject(m.quality))
    }

    /// Each screen is built right before it is rendered (the tab is part of the shared model).
    static func screens() -> [(String, () -> AnyView)] {
        var out: [(String, () -> AnyView)] = []
        let m = model(.protected)
        m.quality.previewHistory(history(network: "iPhone hotspot", via: "Office VPN"))
        m.quality.previewRouter((0..<60).map { 3 + Double($0 % 3) * 0.4 })
        m.quality.picked = ["preview", "preview-home", "preview-travel"]
        m.quality.withSpeed = true
        var times: [String: Double?] = [:]
        for (i, s) in TestServers.all.enumerated() { times[s.id] = 31 + Double((i * 37) % 300) }
        times[TestServers.defaultID] = 44
        times["aws:ap-southeast-7"] = 31
        times["aws:me-central-1"] = .some(nil)
        m.quality.previewServerTimes(times, via: "Office VPN")
        for tab in QualityTab.allCases { out.append((tab.rawValue, { view(m, tab: tab) })) }

        let running = model(.protected)
        running.quality.previewHistory(history(network: "iPhone hotspot", via: "Office VPN"))
        running.quality.previewRouter((0..<60).map { 3 + Double($0 % 3) * 0.4 })
        let now = Date()
        running.quality.previewRun(QualityMonitor.TestRun(network: "iPhone hotspot", withSpeed: true, items: [
            .init(id: "preview", name: "Office VPN", step: .done, stepStarted: now.addingTimeInterval(-40),
                  test: QualityTest(at: now, network: "iPhone hotspot", via: "Office VPN", server: TestServers.defaultID,
                                    ping: 38, jitter: 4, loss: 0, downMbps: 48.2, upMbps: 12.1)),
            .init(id: "preview-home", name: "Home VPN", step: .speed, stepStarted: now.addingTimeInterval(-9),
                  test: QualityTest(at: now, network: "iPhone hotspot", via: "Home VPN", server: TestServers.defaultID,
                                    ping: 29, jitter: 2, loss: 0)),
            .init(id: "preview-travel", name: "Travel VPN"),
        ], startedWith: "Office VPN"))
        out.append(("compare-running", { view(running, tab: .compare) }))

        // Monitor: slow Wi-Fi, a trusted network, and blocked.
        let slow = model(.protected)
        var h = QualityHistory()
        for i in 0..<90 {
            let at = now.addingTimeInterval(Double(i - 90) * 2)
            let router = [58.0, 20, 90, 40, 75, 33][i % 6]
            h.pings.append(PingSample(at: at, network: "iPhone hotspot", via: "Office VPN", internet: i % 33 == 5 ? nil : router + 38 + Double(i % 4) * 3,
                                      server: 68, serverTried: true, router: router))
        }
        slow.quality.previewHistory(h)
        slow.quality.previewRouter([58, 20, 90, 40, 75, 33, 61, 28, 84, 49])
        out.append(("monitor-slow", { view(slow, tab: .monitor) }))

        let trusted = model(.trusted)
        var th = QualityHistory()
        for i in 0..<90 {
            th.pings.append(PingSample(at: now.addingTimeInterval(Double(i - 90) * 2), network: "Office", via: QualityVia.noVPN,
                                       internet: 12 + Double(i % 3) * 0.5, router: 2 + Double(i % 2) * 0.3))
        }
        trusted.quality.previewHistory(th)
        trusted.quality.previewRouter((0..<20).map { 2 + Double($0 % 2) * 0.3 })
        out.append(("monitor-trusted", { view(trusted, tab: .monitor) }))

        let blocked = model(.blocked)
        blocked.quality.previewRouter([4, 4.2, 3.8, 4.1])
        out.append(("monitor-blocked", { view(blocked, tab: .monitor) }))
        return out
    }

    static func history(network: String, via: String) -> QualityHistory {
        let now = Date()
        let cal = Calendar.current
        var h = QualityHistory()
        // The last 10 minutes, every 10 s: a jump and a lost check 4 minutes ago (the VPN dropped).
        for i in 0..<60 {
            let at = now.addingTimeInterval(Double(i - 60) * 10)
            let jump = (i == 35 || i == 36) ? 34.0 : 0
            h.pings.append(PingSample(at: at, network: network, via: via, internet: i == 37 ? nil : 36 + 4 * sin(Double(i) / 3) + jump,
                                      server: 16 + 1.5 * sin(Double(i) / 4), serverTried: true, router: 3 + Double(i % 3) * 0.4))
        }
        let today = cal.startOfDay(for: now)
        h.events = [
            VPNEvent(at: today.addingTimeInterval(-86_400 * 2 + 18 * 3600 + 120), kind: .failed, network: "Wi-Fi", vpn: "Home VPN",
                     detail: "Login refused · used Office VPN"),
            VPNEvent(at: today.addingTimeInterval(-86_400 * 2 + 19 * 3600 + 300), kind: .unstable, seconds: 7800, network: "Wi-Fi",
                     vpn: via, detail: "Up to 96 ms ping · 8 % loss"),
            VPNEvent(at: today, kind: .needed, network: network),
            VPNEvent(at: today.addingTimeInterval(4), kind: .up, seconds: 4, network: network, vpn: via),
            VPNEvent(at: now.addingTimeInterval(-245), kind: .dropped, network: network, vpn: via),
            VPNEvent(at: now.addingTimeInterval(-239), kind: .up, seconds: 6, network: network, vpn: via),
        ]
        func test(_ ago: TimeInterval, _ net: String, _ via: String, _ p: Double, _ j: Double, _ l: Double, _ d: Double, _ u: Double) {
            h.tests.append(QualityTest(at: now.addingTimeInterval(-ago), network: net, via: via, server: TestServers.defaultID,
                                       ping: p, jitter: j, loss: l, downMbps: d, upMbps: u, speedServer: TestServers.defaultID))
        }
        test(3600, network, via, 38, 4, 0, 48.2, 12.1)
        test(3540, network, "Home VPN", 29, 2, 0, 61.5, 18.4)
        test(3480, network, "Travel VPN", 71, 15, 0.02, 22.4, 6.0)
        let pings: [Double] = [40, 39, 41, 44, 58, 38]
        let downs: [Double] = [47, 49, 46, 9, 48, 47]
        for d in 1...6 {
            let ago = Double(d) * 86_400 + 3600
            test(ago, d == 2 ? "Wi-Fi" : network, via, pings[d - 1], d == 2 ? 31 : 4, d == 2 ? 0.03 : 0, downs[d - 1],
                 d == 2 ? 2.2 : 12)
            if d >= 3, d % 2 == 1 { test(ago + 300, network, "Home VPN", 30 + Double(d), 2, 0, 50 + Double(d) * 2, 17) }
            if d == 3 { test(ago + 600, network, "Travel VPN", 74, 14, 0.01, 23, 6.2) }
            test(ago + 36_000, "Office", QualityVia.noVPN, 12, 1, 0, 95.2, 41)
        }
        return h
    }
}

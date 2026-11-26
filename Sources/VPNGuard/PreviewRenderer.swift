import AppKit
import SwiftUI

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

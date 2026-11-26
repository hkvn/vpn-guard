import SwiftUI

@main
struct VPNGuardApp: App {
    @StateObject private var model = AppModel()

    init() {
        // `VPNGuard --render-previews <folder>` draws the UI with made-up data to PNG files.
        PreviewRenderer.runIfRequested()
        ProtectionProbe.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
        } label: {
            Image(nsImage: GlyphRenderer.menuBarImage(model.look.glyph, description: "VPN Guard: \(model.look.title)",
                                                      style: model.menuBarIconStyle))
        }
        .menuBarExtraStyle(.window)

        Window("VPN Guard Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to VPN Guard", id: "welcome") {
            OnboardingView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(AppModel.needsOnboarding ? .presented : .suppressed)
    }
}

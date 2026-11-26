import AppKit
import SwiftUI
import os

/// The window SwiftUI opens from the menu bar icon.
@MainActor
enum MenuBarPanel {
    static func close() {
        for window in NSApp.windows where window.className.contains("MenuBarExtra") && window.isVisible {
            window.orderOut(nil)
        }
    }

    static let log = Logger(subsystem: "local.vpnguard.app", category: "popover")

    /// Makes the menu bar window exactly as big as its content, top edge fixed under the menu bar.
    /// SwiftUI sometimes leaves it taller (empty bands above and below), e.g. when the content got
    /// shorter while the window was closed. Returns true if it had to change the size.
    @discardableResult
    static func fit(_ window: NSWindow, contentSize size: CGSize, reason: String) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 else { return false }
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
        log.notice("fit (\(reason, privacy: .public)): \(Int(content.height)) -> \(Int(size.height)) pt")
        return true
    }
}

/// Sits inside the popover, finds its own window and keeps it as big as the content: when the
/// content changes, and again every time the popover opens or the window is resized by SwiftUI.
struct MenuBarWindowFitter: NSViewRepresentable {
    let size: CGSize
    /// Is the popover on screen? Animations stop while it is not (they cost CPU even when hidden).
    @Binding var visible: Bool

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.size = size
        view.onVisible = { now in
            if visible != now { DispatchQueue.main.async { visible = now } }
        }
        view.fit(reason: "content")
        view.reportVisible()
    }

    final class FitterView: NSView {
        var size: CGSize = .zero
        var onVisible: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        /// Guards against a resize tug-of-war with SwiftUI: at most a few fits per second.
        private var recentFits: [Date] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            let events: [(NSNotification.Name, String)] = [
                (NSWindow.didBecomeKeyNotification, "open"),
                (NSWindow.didChangeOcclusionStateNotification, "shown"),
                (NSWindow.didResizeNotification, "resized"),
            ]
            for (name, reason) in events {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reportVisible()
                        self?.fit(reason: reason)
                        // SwiftUI may set its own size right after showing the window: check once more.
                        DispatchQueue.main.async { self?.fit(reason: reason + " (late)") }
                    }
                })
            }
            fit(reason: "attached")
            reportVisible()
        }

        func reportVisible() {
            guard let window else { return }
            onVisible?(window.isVisible && window.occlusionState.contains(.visible))
        }

        func fit(reason: String) {
            guard let window else { return }
            let now = Date()
            recentFits.removeAll { now.timeIntervalSince($0) > 1 }
            guard recentFits.count < 6 else { return }
            if MenuBarPanel.fit(window, contentSize: size, reason: reason) { recentFits.append(now) }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

/// Small AppKit alerts. Close the menu bar panel and bring the app forward first.
@MainActor
enum Dialogs {
    static func askName(title: String, message: String, button: String, initial: String = "",
                        placeholder: String = "Office, Home…") -> String? {
        MenuBarPanel.close()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (initial.isEmpty ? "Trusted network" : initial) : name
    }

    static func confirm(title: String, message: String, button: String) -> Bool {
        MenuBarPanel.close()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Alert with several buttons. Returns the index of the button pressed.
    static func choose(title: String, message: String, buttons: [String], warning: Bool = false) -> Int {
        MenuBarPanel.close()
        NSApp.activate()
        let alert = NSAlert()
        if warning { alert.alertStyle = .warning }
        alert.messageText = title
        alert.informativeText = message
        for b in buttons { alert.addButton(withTitle: b) }
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func error(_ title: String, _ message: String) {
        MenuBarPanel.close()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

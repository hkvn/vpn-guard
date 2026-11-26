import AppKit

/// The window SwiftUI opens from the menu bar icon.
@MainActor
enum MenuBarPanel {
    static func close() {
        for window in NSApp.windows where window.className.contains("MenuBarExtra") && window.isVisible {
            window.orderOut(nil)
        }
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
    static func choose(title: String, message: String, buttons: [String]) -> Int {
        MenuBarPanel.close()
        NSApp.activate()
        let alert = NSAlert()
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

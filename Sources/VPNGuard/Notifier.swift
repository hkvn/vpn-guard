import Foundation
import UserNotifications
import os

private let notifierLog = Logger(subsystem: "local.vpnguard.app", category: "notifications")

/// macOS notifications. Only works inside the app bundle (not for `swift run` or previews).
@MainActor
final class Notifier {

    /// UNUserNotificationCenter needs a real app bundle; without one it stops the process.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Asks macOS once (it shows its own question); later calls just report the answer.
    func authorize(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            notifierLog.notice("notifications allowed: \(granted, privacy: .public) \(error?.localizedDescription ?? "", privacy: .public)")
            Task { @MainActor in done(granted) }
        }
    }

    enum Access: Equatable { case allowed, refused, notAnswered }

    func access(_ done: @escaping @MainActor (Access) -> Void) {
        guard let center else { return }
        center.getNotificationSettings { settings in
            let access: Access
            switch settings.authorizationStatus {
            case .denied: access = .refused
            case .notDetermined: access = .notAnswered
            default: access = .allowed
            }
            notifierLog.notice("notification access: \(String(describing: access), privacy: .public)")
            Task { @MainActor in done(access) }
        }
    }

    func send(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // One id: a newer notice replaces the older one instead of piling up.
        let request = UNNotificationRequest(identifier: "vpnguard.state", content: content, trigger: nil)
        center.add(request) { error in
            notifierLog.notice("sent \"\(title, privacy: .public)\" \(error?.localizedDescription ?? "ok", privacy: .public)")
        }
    }
}

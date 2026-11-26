import Foundation

/// Sleep and wake. The Mac can go to sleep at a trusted place and wake up somewhere else (lid closed
/// at home, opened at a café). For a moment macOS may still show the old network and its router,
/// and a café Wi-Fi can be up before the helper looks again. So the lock goes on before sleep, and
/// after the wake a router counts only once its hardware address was read again from a fresh answer.
public struct WakeGuard: Equatable, Sendable {
    /// Between "will sleep" and the wake.
    public private(set) var asleep = false
    /// When the Mac woke and the routers are not read again yet. Nil: nothing to check.
    public private(set) var wokeAt: Date?

    /// After this long the network values macOS shows are fresh again, whatever the routers say
    /// (some USB modems never show a hardware address).
    public static let maxCheck: TimeInterval = 60

    public init() {}

    /// True while the routers macOS shows may belong to the place where the Mac went to sleep.
    public var checking: Bool { asleep || wokeAt != nil }

    public mutating func willSleep() {
        asleep = true
        wokeAt = nil
    }

    /// macOS asked, then did not sleep after all: nothing changed.
    public mutating func sleepCancelled() {
        asleep = false
    }

    public mutating func didWake(at date: Date) {
        asleep = false
        wokeAt = date
    }

    /// `routersFresh`: every network has a router hardware address read since the wake.
    /// Returns true when the check ends with this call.
    @discardableResult
    public mutating func update(routersFresh: Bool, now: Date) -> Bool {
        guard !asleep, let wokeAt else { return false }
        guard routersFresh || now.timeIntervalSince(wokeAt) >= Self.maxCheck else { return false }
        self.wokeAt = nil
        return true
    }
}

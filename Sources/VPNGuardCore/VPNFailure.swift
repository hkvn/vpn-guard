import Foundation

/// Why a VPN did not connect, in words for people.
public enum VPNFailure: Equatable, Sendable {
    /// The server refused the name or password. `code` is the MS-CHAP error number if the server
    /// sent one (691 wrong name or password, 647 account off, 648 password expired, 649 no permission).
    case loginRefused(code: Int?)
    /// Nothing came back from the server.
    case noAnswer
    /// The server answered, but the secure (IPSec) connection could not be set up.
    case secretRefused
    case nameNotFound
    /// It was connected, then the server stopped answering.
    case connectionLost
    /// WireGuard: the server never completed a handshake.
    case wireGuardNoAnswer
    /// A full sentence from the helper (WireGuard set-up problems).
    case message(String)
    /// It failed and macOS did not say why.
    case unknown

    /// A few words, for a label in a list: "Login refused".
    public var label: String {
        switch self {
        case .loginRefused(let code):
            switch code {
            case 646: return "Login not allowed now"
            case 647: return "Account turned off"
            case 648: return "Password expired"
            case 649: return "No VPN permission"
            default: return "Login refused"
            }
        case .noAnswer, .wireGuardNoAnswer: return "Server did not answer"
        case .secretRefused: return "Shared secret not accepted"
        case .nameNotFound: return "Server name not found"
        case .connectionLost: return "Connection lost"
        case .message, .unknown: return "Could not connect"
        }
    }

    /// The reason as part of a sentence, without a full stop: "the server refused the login".
    /// Nil when there is nothing short to say.
    public var short: String? {
        switch self {
        case .loginRefused(let code):
            switch code {
            case 646: return "the account may not log in at this time"
            case 647: return "the account is turned off on the server"
            case 648: return "the password has expired"
            case 649: return "the account may not use the VPN"
            default: return "the server refused the login"
            }
        case .noAnswer: return "the server did not answer"
        case .secretRefused: return "the server did not accept the shared secret"
        case .nameNotFound: return "the server name was not found"
        case .connectionLost: return "the server stopped answering"
        case .wireGuardNoAnswer: return "the server does not answer"
        case .message, .unknown: return nil
        }
    }

    /// One more short sentence that helps, if there is one.
    private var hint: String? {
        switch self {
        case .loginRefused(let code) where code == nil || code == 691:
            return "The account may be in use on another device."
        case .noAnswer: return "It may be down, or this network blocks VPNs."
        case .wireGuardNoAnswer: return "Check that this Mac's public key is on the server."
        default: return nil
        }
    }

    /// For the popover: "Office VPN could not connect: the server refused the login. The account may…"
    public func sentence(vpn: String) -> String {
        if case .message(let text) = self { return "\(vpn) could not connect. \(text)" }
        guard let short else { return "\(vpn) could not connect. VPN Guard keeps trying." }
        return ["\(vpn) could not connect: \(short).", hint].compactMap { $0 }.joined(separator: " ")
    }

    /// For a notification: one short sentence.
    public func brief(vpn: String) -> String {
        guard let short else { return "\(vpn) could not connect." }
        return "\(vpn) could not connect: \(short)."
    }

    /// For the VPN's details: what happened and what to check.
    public var explanation: String {
        switch self {
        case .loginRefused(let code):
            let number = code.map { " (error \($0))" } ?? ""
            switch code {
            case 646: return "The server says this account may not log in at this time\(number)."
            case 647: return "The account is turned off on the server\(number). Ask the person who runs the VPN."
            case 648: return "The password has expired\(number). Set a new one on the server, then in System Settings."
            case 649: return "The account has no permission to use the VPN\(number). Ask the person who runs the VPN."
            default:
                return "The server refused the name or password\(number). Check them in System Settings. If they are right, the account may be in use on another device, or turned off on the server."
            }
        case .noAnswer:
            return "Nothing came back from the server. It may be down or have a new address, or this network blocks VPN connections. Try another network, such as your iPhone hotspot."
        case .secretRefused:
            return "The server answered, but the secure connection could not be set up. The shared secret may be wrong. Check it in System Settings."
        case .nameNotFound:
            return "The server's name could not be looked up. Check the server address."
        case .connectionLost:
            return "The VPN was connected, then the server stopped answering, so macOS closed it."
        case .wireGuardNoAnswer:
            return "The server does not answer. Check the server address and port, and that this Mac's public key was added on the server."
        case .message(let text):
            return text
        case .unknown:
            return "macOS did not say why. Connect once from System Settings → VPN to see its message."
        }
    }

    /// pppd's exit code (the "LastCause" macOS reports for L2TP and PPTP), for when the log says nothing.
    /// Only the codes documented in pppd(8) that say something useful.
    public static func from(pppLastCause code: Int) -> VPNFailure? {
        switch code {
        case 19: return .loginRefused(code: nil)   // "We failed to authenticate ourselves to the peer."
        case 15: return .connectionLost            // "The peer is not responding to echo requests."
        default: return nil
        }
    }
}

/// Reads why the last L2TP / PPTP connection failed from macOS's /var/log/ppp.log.
public enum PPPLog {
    /// - Parameters:
    ///   - text: the end of ppp.log.
    ///   - server: the VPN's server as typed in its settings. If the last attempt in the log went to
    ///     another server, the log is about another VPN and the answer is nil.
    ///   - since: when this attempt started. Older lines are ignored. Nil: use the last attempt.
    public static func lastFailure(in text: String, server: String? = nil, since: Date? = nil,
                                   timeZone: TimeZone = .current) -> VPNFailure? {
        var lines: [Substring] = []
        var keep = since == nil
        for line in text.split(whereSeparator: \.isNewline) {
            if let since, let at = date(of: line, timeZone: timeZone) { keep = at >= since.addingTimeInterval(-1) }
            if keep { lines.append(line) }
        }
        // The attempt starts at the last "connecting to server" line.
        if let start = lines.lastIndex(where: { $0.contains("connecting to server '") }) {
            if let server, !server.isEmpty,
               !lines[start].lowercased().contains("'\(server.lowercased())'") { return nil }
            if since == nil { lines = Array(lines[start...]) }
        } else if since == nil {
            return nil
        }
        // What matters is what happened after the last time it was up.
        if let up = lines.lastIndex(where: { $0.contains("ipcp: up") }) { lines = Array(lines[(up + 1)...]) }
        let all = lines.map { $0.lowercased() }
        func any(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }

        if any("chap failure") || any("authentication failed") {
            return .loginRefused(code: all.lazy.compactMap(Self.msChapError).first)
        }
        if all.contains(where: { $0.contains("host") && $0.contains("not found") }) || any("cannot resolve") {
            return .nameNotFound
        }
        if any("ipsec connection failed") {
            return any("phase 1 server replied") ? .secretRefused : .noAnswer
        }
        if any("cannot connect to the server") { return .noAnswer }
        if all.contains(where: { $0.contains("no response to") && $0.contains("echo-request") }) {
            return .connectionLost
        }
        return nil
    }

    /// "E=691" in an MS-CHAP failure line.
    static func msChapError(_ line: String) -> Int? {
        guard let r = line.range(of: "e=") else { return nil }
        let digits = line[r.upperBound...].prefix { $0.isNumber }
        guard (3...4).contains(digits.count) else { return nil }
        return Int(digits)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Lines start like "Thu Nov 26 15:10:33 2026 : ".
    static func date(of line: Substring, timeZone: TimeZone) -> Date? {
        guard let end = line.range(of: " : ") else { return nil }
        let parts = line[..<end.lowerBound].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 5, let month = months.firstIndex(of: parts[1].lowercased()),
              let day = Int(parts[2]), let year = Int(parts[4]) else { return nil }
        let clock = parts[3].split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month + 1, day: day,
                                                  hour: clock[0], minute: clock[1], second: clock[2]))
    }
}

/// When the chosen VPN does not connect: which other VPN to try.
public enum BackupVPN {
    /// Failed tries in a row before the next VPN is tried.
    public static let triesBeforeBackup = 3
    /// WireGuard has no "failed" event: this long without an answer counts as failed.
    public static let wireGuardPatience: TimeInterval = 25

    /// The next VPN to try on this network: the first candidate (in list order) that is not the
    /// main VPN and has not failed here. Nil when none is left.
    public static func next(main: String?, failed: Set<String>, candidates: [String]) -> String? {
        candidates.first { $0 != main && !failed.contains($0) }
    }
}

/// macOS notifications: only when something needs the user.
public enum VPNNotice: String, Equatable, Sendable {
    case blocked, backup, protectedAgain
}

public enum Notices {
    public enum Situation: Equatable, Sendable {
        /// Locked on an untrusted network and no VPN is connected.
        case blocked
        /// A backup VPN is connected.
        case backup
        /// The chosen VPN is connected.
        case protected
        /// Trusted network, protection off or paused, no network, or the user stopped the VPN.
        case quiet
    }

    /// Blocked this long -> tell the user. A normal "joined a café, VPN up in a few seconds" stays silent.
    public static let blockedPatience: TimeInterval = 20

    /// What to tell the user now, if anything. `lastSent` is the last notice on this network
    /// (the caller forgets it when the situation is quiet or the network changes).
    public static func decide(situation: Situation, blockedFor: TimeInterval, failedTries: Int,
                              lastSent: VPNNotice?) -> VPNNotice? {
        switch situation {
        case .blocked:
            guard lastSent != .blocked else { return nil }
            return blockedFor >= blockedPatience || failedTries >= BackupVPN.triesBeforeBackup ? .blocked : nil
        case .backup:
            return lastSent == .backup ? nil : .backup
        case .protected:
            return lastSent == .blocked || lastSent == .backup ? .protectedAgain : nil
        case .quiet:
            return nil
        }
    }

    /// Title and text. `vpn` is the VPN in use (or tried), `main` the chosen one when a backup is used.
    public static func text(_ notice: VPNNotice, vpn: String?, main: String? = nil,
                            reason: VPNFailure? = nil) -> (title: String, body: String) {
        switch notice {
        case .blocked:
            guard let vpn else { return ("Internet blocked", "Choose the VPN to use on networks you don't trust.") }
            return ("Internet blocked",
                    reason?.brief(vpn: vpn) ?? "\(vpn) is not connected, so nothing gets out on this network.")
        case .backup:
            return ("Using your backup VPN",
                    "\(main ?? "Your VPN") could not connect. \(vpn ?? "A backup VPN") is used on this network.")
        case .protectedAgain:
            return ("Protected again", "\(vpn ?? "Your VPN") is connected.")
        }
    }
}

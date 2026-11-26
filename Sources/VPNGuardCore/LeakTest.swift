import Foundation

/// What one untrusted network card let out during the protection test.
public struct LeakProbe: Equatable, Sendable {
    public var interface: String
    /// Name for people: "Wi-Fi", "iPhone USB".
    public var label: String
    /// A connection straight through this card reached the test address. Nil: could not be tested.
    public var internetGotOut: Bool?
    /// A name lookup straight through this card got an answer. Nil: could not be tested.
    public var dnsGotOut: Bool?
    /// An IPv6 connection straight through this card got out. Nil: the card has no IPv6.
    public var ipv6GotOut: Bool?

    public init(interface: String, label: String, internetGotOut: Bool?, dnsGotOut: Bool?, ipv6GotOut: Bool?) {
        self.interface = interface
        self.label = label
        self.internetGotOut = internetGotOut
        self.dnsGotOut = dnsGotOut
        self.ipv6GotOut = ipv6GotOut
    }
}

public struct LeakCheck: Equatable, Sendable, Identifiable {
    public enum Result: Equatable, Sendable { case pass, fail, skipped }
    public var id: String
    public var title: String
    public var detail: String
    public var result: Result

    public init(id: String, title: String, detail: String, result: Result) {
        self.id = id
        self.title = title
        self.detail = detail
        self.result = result
    }
}

public struct LeakReport: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable { case noLeaks, leak, nothingToTest, notOn }
    public var verdict: Verdict
    public var title: String
    public var subtitle: String
    public var checks: [LeakCheck]

    public init(verdict: Verdict, title: String, subtitle: String, checks: [LeakCheck]) {
        self.verdict = verdict
        self.title = title
        self.subtitle = subtitle
        self.checks = checks
    }
}

/// The protection test: turns what the probes saw into pass / fail lines.
public enum LeakTest {
    /// The address the test tries to reach (Cloudflare's public resolver).
    public static let testAddress = "1.1.1.1"
    public static let testAddress6 = "2606:4700:4700::1111"

    /// When there is nothing to probe (trusted network, protection off…), the report to show. Nil: run the probes.
    public static func withoutProbes(reason: GuardReason, trustedNames: String) -> LeakReport? {
        switch reason {
        case .untrusted, .mixed, .resolving:
            return nil
        case .trusted:
            return LeakReport(verdict: .nothingToTest, title: "Nothing to test here",
                              subtitle: "You are at \(trustedNames.isEmpty ? "a trusted network" : "\(trustedNames), a trusted network")",
                              checks: [LeakCheck(id: "open", title: "The internet is open here on purpose",
                                                 detail: "Run the test on a network you don't trust, for example your iPhone hotspot.",
                                                 result: .skipped)])
        case .noNetwork:
            return LeakReport(verdict: .nothingToTest, title: "No network", subtitle: "Join a network, then test again",
                              checks: [])
        case .disabled, .paused:
            let paused = reason == .paused
            return LeakReport(verdict: .notOn, title: paused ? "Protection is paused" : "Protection is off",
                              subtitle: paused ? "Resume it, then test again" : "Turn it on, then test again",
                              checks: [LeakCheck(id: "open", title: "The internet is open right now",
                                                 detail: "Nothing is blocked while protection is \(paused ? "paused" : "off").",
                                                 result: .skipped)])
        }
    }

    /// - Parameters:
    ///   - rulesActive: the helper says the lock rules are loaded.
    ///   - probes: one per untrusted network card.
    ///   - vpnName: the VPN in use; `vpnConnected` whether it is up; `viaVPNWorks` whether the test
    ///     server answered through it (nil: not tried).
    public static func report(rulesActive: Bool, probes: [LeakProbe], vpnName: String?, vpnConnected: Bool,
                              viaVPNWorks: Bool?) -> LeakReport {
        let cards = list(probes.map(\.label))
        var checks = [LeakCheck(
            id: "rules", title: "The firewall rules are active",
            detail: rulesActive ? "VPN Guard's rules are loaded in the macOS firewall."
                                : "The rules are not loaded. Reinstall the helper, then test again.",
            result: rulesActive ? .pass : .fail)]

        func outside(_ id: String, _ title: String, _ got: (LeakProbe) -> Bool?, pass: String, what: String) -> LeakCheck {
            let leaking = probes.filter { got($0) == true }
            if !leaking.isEmpty {
                return LeakCheck(id: id, title: title,
                                 detail: "\(what) straight through \(list(leaking.map(\.label))) got out. Reinstall the helper, then test again.",
                                 result: .fail)
            }
            if probes.isEmpty || probes.contains(where: { got($0) == nil }) {
                return LeakCheck(id: id, title: title, detail: "This could not be tested on \(cards.isEmpty ? "this Mac" : cards).",
                                 result: .skipped)
            }
            return LeakCheck(id: id, title: title, detail: pass, result: .pass)
        }
        checks.append(outside("internet", "Direct internet is blocked", \.internetGotOut,
                              pass: "A connection outside the VPN, straight through \(cards), did not get out.",
                              what: "A connection"))
        checks.append(outside("dns", "Direct DNS is blocked", \.dnsGotOut,
                              pass: "A name lookup outside the VPN did not get out.", what: "A name lookup"))
        if probes.allSatisfy({ $0.ipv6GotOut == nil }) {
            checks.append(LeakCheck(id: "ipv6", title: "IPv6", detail: "This network has no IPv6, so nothing to test.",
                                    result: .skipped))
        } else {
            let leaking = probes.filter { $0.ipv6GotOut == true }
            checks.append(LeakCheck(
                id: "ipv6", title: "Direct IPv6 is blocked",
                detail: leaking.isEmpty ? "No IPv6 connection got out."
                    : "An IPv6 connection straight through \(list(leaking.map(\.label))) got out. Reinstall the helper, then test again.",
                result: leaking.isEmpty ? .pass : .fail))
        }
        let leak = checks.contains { $0.result == .fail }

        let vpn = vpnName ?? "the VPN"
        if !vpnConnected {
            checks.append(LeakCheck(id: "vpn", title: "Internet through the VPN",
                                    detail: "\(vpnName.map { "\($0) is" } ?? "No VPN is") not connected, so nothing gets out here. That is how it should be.",
                                    result: .skipped))
        } else if viaVPNWorks == true {
            checks.append(LeakCheck(id: "vpn", title: "Internet through the VPN works",
                                    detail: "Reached the test server through \(vpn).", result: .pass))
        } else {
            checks.append(LeakCheck(id: "vpn", title: "Internet through the VPN works",
                                    detail: "\(vpn) is connected, but the test server did not answer through it.",
                                    result: viaVPNWorks == nil ? .skipped : .fail))
        }

        let on = cards.isEmpty ? "this network" : "\(cards) (not trusted)"
        return LeakReport(verdict: leak ? .leak : .noLeaks,
                          title: leak ? "Leak found" : "No leaks found",
                          subtitle: leak ? "Something got out outside the VPN"
                                         : "Tested on \(on)\(vpnConnected ? " with \(vpn)" : "")",
                          checks: checks)
    }

    private static func list(_ names: [String]) -> String {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.joined(separator: " and ")
    }
}

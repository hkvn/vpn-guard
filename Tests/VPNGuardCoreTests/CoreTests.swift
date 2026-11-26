import XCTest
@testable import VPNGuardCore

final class NetTests: XCTestCase {
    func testNormalizeMAC() {
        XCTAssertEqual(Net.normalizeMAC("48:8F:5A:1:2:3"), "48:8f:5a:01:02:03")
        XCTAssertEqual(Net.normalizeMAC("48-8f-5a-01-02-03"), "48:8f:5a:01:02:03")
        XCTAssertEqual(Net.normalizeMAC(" aa:bb:cc:dd:ee:ff "), "aa:bb:cc:dd:ee:ff")
        XCTAssertNil(Net.normalizeMAC("aa:bb:cc:dd:ee"))
        XCTAssertNil(Net.normalizeMAC("aa:bb:cc:dd:ee:ff:00"))
        XCTAssertNil(Net.normalizeMAC("zz:bb:cc:dd:ee:ff"))
        XCTAssertNil(Net.normalizeMAC("aaa:bb:cc:dd:ee:ff"))
        XCTAssertNil(Net.normalizeMAC("aa::cc:dd:ee:ff"))
        XCTAssertNil(Net.normalizeMAC("00:00:00:00:00:00"))
        XCTAssertNil(Net.normalizeMAC("ff:ff:ff:ff:ff:ff"))
    }

    func testIPv4() {
        XCTAssertTrue(Net.isIPv4("203.0.113.10"))
        XCTAssertTrue(Net.isIPv4("10.0.0.1"))
        XCTAssertFalse(Net.isIPv4("vpn.example.com"))
        XCTAssertFalse(Net.isIPv4("1.2.3.4 } pass all"))
        XCTAssertFalse(Net.isIPv4("::1"))
        XCTAssertFalse(Net.isIPv4("256.1.1.1"))
    }

    func testInterfaceKinds() {
        XCTAssertTrue(Net.isInternal("lo0"))
        XCTAssertTrue(Net.isInternal("utun7"))
        XCTAssertTrue(Net.isInternal("ppp0"))
        XCTAssertTrue(Net.isInternal("bridge100"))
        XCTAssertTrue(Net.isInternal("vmenet3"))
        XCTAssertFalse(Net.isInternal("bridge0"), "Thunderbolt Bridge is a real link")
        XCTAssertFalse(Net.isInternal("en0"))
        XCTAssertFalse(Net.isInternal("awdl0"))
        XCTAssertTrue(Net.isValidInterfaceName("en0"))
        XCTAssertFalse(Net.isValidInterfaceName("en0 }"))
        XCTAssertFalse(Net.isValidInterfaceName(""))
    }
}

final class PolicyTests: XCTestCase {
    let now = Date()
    let office = TrustedNetwork(name: "Office", routerMAC: "aa:aa:aa:aa:aa:aa", routerIP: "192.168.88.1")

    func link(_ mac: String?, trusted: String? = nil, ifname: String = "en0") -> NetworkLink {
        NetworkLink(interface: ifname, routerIP: "192.168.1.1", routerMAC: mac, trustedName: trusted)
    }

    func testDisabledIsOpen() {
        let d = Policy.decide(config: GuardConfig(enabled: false), links: [link("bb:bb:bb:bb:bb:bb")], now: now)
        XCTAssertEqual(d.mode, .open)
        XCTAssertEqual(d.reason, .disabled)
    }

    func testPausedIsOpenUntilTheEnd() {
        var c = GuardConfig(enabled: true)
        c.pausedUntil = now.addingTimeInterval(60)
        XCTAssertEqual(Policy.decide(config: c, links: [link("bb:bb:bb:bb:bb:bb")], now: now).reason, .paused)
        c.pausedUntil = now.addingTimeInterval(-1)
        XCTAssertEqual(Policy.decide(config: c, links: [link("bb:bb:bb:bb:bb:bb")], now: now).mode, .locked)
    }

    func testNoNetworkLocks() {
        let d = Policy.decide(config: GuardConfig(enabled: true), links: [], now: now)
        XCTAssertEqual(d.mode, .locked)
        XCTAssertEqual(d.reason, .noNetwork)
    }

    func testUnknownRouterLocks() {
        let d = Policy.decide(config: GuardConfig(enabled: true), links: [link(nil)], now: now)
        XCTAssertEqual(d.mode, .locked)
        XCTAssertEqual(d.reason, .resolving)
    }

    func testTrustedOpens() {
        let c = GuardConfig(enabled: true, trusted: [office])
        let d = Policy.decide(config: c, links: [link(office.routerMAC, trusted: "Office")], now: now)
        XCTAssertEqual(d.mode, .open)
        XCTAssertEqual(d.reason, .trusted)
    }

    /// Lid closed at home, opened at a café: until the router is read again, home's trust and a pause
    /// do not count. Protection off stays off.
    func testUnconfirmedRoutersLockEvenTrustedOrPaused() {
        var c = GuardConfig(enabled: true, trusted: [office])
        let home = [link(office.routerMAC, trusted: "Office")]
        XCTAssertEqual(Policy.decide(config: c, links: home, now: now, routersUnconfirmed: true).mode, .locked)
        XCTAssertEqual(Policy.decide(config: c, links: home, now: now, routersUnconfirmed: true).reason, .resolving)
        XCTAssertEqual(Policy.decide(config: c, links: [], now: now, routersUnconfirmed: true).reason, .noNetwork)
        c.pausedUntil = now.addingTimeInterval(600)
        XCTAssertEqual(Policy.decide(config: c, links: home, now: now, routersUnconfirmed: true).mode, .locked)
        c.enabled = false
        XCTAssertEqual(Policy.decide(config: c, links: home, now: now, routersUnconfirmed: true).mode, .open)
    }

    func testWakeGuard() {
        var w = WakeGuard()
        XCTAssertFalse(w.checking)
        XCTAssertFalse(w.update(routersFresh: true, now: now), "nothing to check before a sleep")

        w.willSleep()
        XCTAssertTrue(w.checking)
        XCTAssertFalse(w.update(routersFresh: true, now: now), "asleep: a router read now is still the old place")
        w.sleepCancelled()
        XCTAssertFalse(w.checking)

        w.willSleep()
        w.didWake(at: now)
        XCTAssertTrue(w.checking)
        XCTAssertFalse(w.update(routersFresh: false, now: now.addingTimeInterval(2)))
        XCTAssertTrue(w.checking)
        XCTAssertTrue(w.update(routersFresh: true, now: now.addingTimeInterval(3)))
        XCTAssertFalse(w.checking)

        w.willSleep()
        w.didWake(at: now)
        XCTAssertTrue(w.update(routersFresh: false, now: now.addingTimeInterval(WakeGuard.maxCheck)),
                      "a router that never answers does not keep the check on for ever")
        XCTAssertFalse(w.checking)
    }

    /// 1.2.0: office + iPhone USB locks only the untrusted card ("mixed"), not the whole Mac.
    func testTrustedPlusUntrustedIsMixed() {
        let c = GuardConfig(enabled: true, trusted: [office])
        let links = [link(office.routerMAC, trusted: "Office"), link("cc:cc:cc:cc:cc:cc", ifname: "en7")]
        let d = Policy.decide(config: c, links: links, now: now)
        XCTAssertEqual(d.mode, .locked)
        XCTAssertEqual(d.reason, .mixed)
    }

    func testTrustedPlusUnknownIsMixed() {
        let c = GuardConfig(enabled: true, trusted: [office])
        let links = [link(office.routerMAC, trusted: "Office"), link(nil, ifname: "en7")]
        XCTAssertEqual(Policy.decide(config: c, links: links, now: now).reason, .mixed, "an unknown card is VPN only")
        XCTAssertEqual(Policy.decide(config: c, links: links, now: now).mode, .locked)
    }

    func testNoTrustedCardStillLocksEverything() {
        let c = GuardConfig(enabled: true, trusted: [office])
        let links = [link("cc:cc:cc:cc:cc:cc"), link(nil, ifname: "en7")]
        XCTAssertEqual(Policy.decide(config: c, links: links, now: now).reason, .untrusted)
    }

    func testTrustMatchingUsesNormalizedMAC() {
        let c = GuardConfig(enabled: true, trusted: [office])
        XCTAssertEqual(c.trustedNetwork(matchingMAC: "AA:AA:AA:AA:AA:AA")?.name, "Office")
        XCTAssertNil(c.trustedNetwork(matchingMAC: "ab:aa:aa:aa:aa:aa"))
        XCTAssertNil(c.trustedNetwork(matchingMAC: nil))
    }
}

final class RulesTests: XCTestCase {
    func testLockRules() {
        let rules = PFRules.lockRules(vpnServers: ["203.0.113.10", "203.0.113.10"],
                                      routers: ["172.20.10.1"],
                                      interfaces: ["en0", "bridge100", "vmenet0", "awdl0", "bridge0"])
        let lines = rules.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("pass out quick inet from any to { 203.0.113.10 } no state"))
        XCTAssertTrue(lines.contains("pass in quick inet from { 203.0.113.10 } to any no state"))
        XCTAssertTrue(lines.contains { $0.contains("icmp") && $0.contains("172.20.10.1") })
        XCTAssertEqual(lines.suffix(2), ["block return out quick all", "block drop in quick all"])

        let passOn = lines.first { $0.hasPrefix("pass quick on") } ?? ""
        XCTAssertTrue(passOn.contains(" lo0 "))
        XCTAssertTrue(passOn.contains(" ppp0 "))
        XCTAssertTrue(passOn.contains(" bridge100 "))
        XCTAssertFalse(passOn.contains(" en0 "), "real cards must never be passed")
        XCTAssertFalse(passOn.contains(" awdl0 "))
        XCTAssertFalse(passOn.contains(" bridge0 "))
    }

    func testBadInputNeverReachesRules() {
        let rules = PFRules.lockRules(vpnServers: ["1.2.3.4 } pass all", "vpn.example.com"],
                                      routers: ["x; pass"],
                                      interfaces: ["utun9 } pass"])
        XCTAssertFalse(rules.contains("pass all"))
        XCTAssertFalse(rules.contains("example"))
        XCTAssertFalse(rules.contains("icmp"))
        XCTAssertFalse(rules.contains("to {"), "no server rules without a valid server")
    }

    func testNoServersStillBlocks() {
        let rules = PFRules.lockRules(vpnServers: [], routers: [], interfaces: [])
        XCTAssertTrue(rules.hasSuffix("block return out quick all\nblock drop in quick all\n"))
    }
}

final class WireTests: XCTestCase {
    func testOldConfigDecodes() throws {
        let json = #"{"trusted":[{"id":"6A1E8E0B-6C0C-4C4B-9E32-3D7C2F1A0B11","name":"Home","routerMAC":"aa:bb:cc:dd:ee:ff","addedAt":"2026-11-26T08:00:00Z"}]}"#
        let c = try Wire.decode(GuardConfig.self, from: Data(json.utf8))
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.vpnServers, [])
        XCTAssertEqual(c.trusted.first?.name, "Home")
    }

    func testCommandRoundTrip() throws {
        let id = UUID()
        for cmd: HelperCommand in [.status, .trustCurrent(name: "Office"), .untrust(id: id), .pause(minutes: 5),
                                   .setEnabled(true), .setVPNServers(["1.2.3.4"])] {
            let back = try Wire.decode(HelperCommand.self, from: Wire.encode(cmd))
            XCTAssertEqual(String(describing: back), String(describing: cmd))
        }
    }
}

final class ServerTests: XCTestCase {
    func testHostNames() {
        XCTAssertTrue(Net.isHostName("vpn.example.com"))
        XCTAssertTrue(Net.isHostName("a1b2c3d4e5f6.sn.mynetname.net"))
        XCTAssertFalse(Net.isHostName("203.0.113.10"))
        XCTAssertFalse(Net.isHostName("localhost"))
        XCTAssertFalse(Net.isHostName("VPN.example.com"), "callers lower-case first")
        XCTAssertFalse(Net.isHostName("vpn..example.com"))
        XCTAssertFalse(Net.isHostName("-vpn.example.com"))
        XCTAssertFalse(Net.isHostName("vpn.example.com\n1.2.3.4 evil"))
        XCTAssertFalse(Net.isHostName("vpn example.com"))
        XCTAssertFalse(Net.isHostName("1.2.3"))
    }

    func testNormalizeServer() {
        XCTAssertEqual(GuardConfig.normalizeServer(" VPN.Example.com. "), "vpn.example.com")
        XCTAssertEqual(GuardConfig.normalizeServer("203.0.113.10"), "203.0.113.10")
    }

    func testAllowedIPsUseLookups() {
        var c = GuardConfig(vpnServers: ["203.0.113.10", "vpn.example.com", "home.example.net"])
        XCTAssertEqual(c.allowedIPs, ["203.0.113.10"], "host names without a lookup add nothing")
        c.hostIPs = ["vpn.example.com": ["198.51.100.20"], "home.example.net": ["203.0.113.10"]]
        XCTAssertEqual(c.allowedIPs, ["203.0.113.10", "198.51.100.20"])
        c.hostIPs["vpn.example.com"] = ["bad } pass all"]
        XCTAssertEqual(c.allowedIPs, ["203.0.113.10"])
    }
}

final class PinnedDNSTests: XCTestCase {
    func query(_ name: String, type: UInt16 = 1, id: UInt16 = 0xBEEF) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
        q += [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1]
        return q
    }

    let pins = ["vpn.example.com": ["198.51.100.20", "1.2.3.4"]]

    func testAnswersPinnedName() throws {
        let q = query("VPN.example.com")
        let r = try XCTUnwrap(PinnedDNS.reply(to: q, pins: pins))
        XCTAssertEqual(Array(r[0..<2]), [0xBE, 0xEF], "same id")
        XCTAssertEqual(r[2] & 0x80, 0x80, "is a response")
        XCTAssertEqual(r[3] & 0x0F, 0, "NOERROR")
        XCTAssertEqual(Int(r[6]) << 8 | Int(r[7]), 2, "two answers")
        XCTAssertEqual(Array(r[12..<q.count]), Array(q[12...]), "question echoed")
        let first = q.count
        XCTAssertEqual(Array(r[first..<(first + 2)]), [0xC0, 0x0C])
        XCTAssertEqual(Array(r[(first + 12)..<(first + 16)]), [198, 51, 100, 20])
        XCTAssertEqual(r.count, q.count + 2 * 16)
    }

    func testOtherNamesAndTypes() throws {
        let nx = try XCTUnwrap(PinnedDNS.reply(to: query("www.example.com"), pins: pins))
        XCTAssertEqual(nx[3] & 0x0F, 3, "NXDOMAIN for names we do not own")
        let aaaa = try XCTUnwrap(PinnedDNS.reply(to: query("vpn.example.com", type: 28), pins: pins))
        XCTAssertEqual(aaaa[3] & 0x0F, 0)
        XCTAssertEqual(aaaa[7], 0, "no IPv6 answer")
    }

    func testGarbageIsIgnored() {
        XCTAssertNil(PinnedDNS.reply(to: [1, 2, 3], pins: pins))
        var response = query("vpn.example.com")
        response[2] |= 0x80
        XCTAssertNil(PinnedDNS.reply(to: response, pins: pins), "never answer a response")
        var cut = query("vpn.example.com")
        cut.removeLast(6)
        XCTAssertNil(PinnedDNS.reply(to: cut, pins: pins))
        XCTAssertNil(PinnedDNS.reply(to: [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 0x0C, 0, 1, 0, 1], pins: pins),
                     "compression pointer in a question is refused")
    }
}

final class VPNProfileTests: XCTestCase {
    func l2tp() -> VPNProfileDraft {
        var d = VPNProfileDraft()
        d.name = "Office VPN"
        d.server = " VPN.Example.com "
        d.account = "alice"
        d.password = "p@ss"
        d.sharedSecret = "s3cret"
        d.dnsServers = "1.1.1.1, 8.8.8.8"
        return d
    }

    func plist(_ d: VPNProfileDraft) throws -> [String: Any] {
        let data = try d.mobileconfig()
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testL2TPProfile() throws {
        let p = try plist(l2tp())
        XCTAssertEqual(p["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(p["PayloadScope"] as? String, "System")
        let vpn = try XCTUnwrap((p["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(vpn["PayloadType"] as? String, "com.apple.vpn.managed")
        XCTAssertEqual(vpn["VPNType"] as? String, "L2TP")
        XCTAssertEqual(vpn["UserDefinedName"] as? String, "Office VPN")
        XCTAssertEqual((vpn["IPv4"] as? [String: Any])?["OverridePrimary"] as? Int, 1, "send all traffic")
        let ppp = try XCTUnwrap(vpn["PPP"] as? [String: Any])
        XCTAssertEqual(ppp["CommRemoteAddress"] as? String, "vpn.example.com")
        XCTAssertEqual(ppp["AuthName"] as? String, "alice")
        XCTAssertEqual(ppp["AuthPassword"] as? String, "p@ss")
        let ipsec = try XCTUnwrap(vpn["IPSec"] as? [String: Any])
        XCTAssertEqual(ipsec["AuthenticationMethod"] as? String, "SharedSecret")
        XCTAssertEqual(ipsec["SharedSecret"] as? Data, Data("s3cret".utf8))
        XCTAssertEqual((vpn["DNS"] as? [String: Any])?["ServerAddresses"] as? [String], ["1.1.1.1", "8.8.8.8"])
    }

    func testIKEv2Profile() throws {
        var d = l2tp()
        d.kind = .ikev2
        d.sharedSecret = ""
        d.dnsServers = ""
        let vpn = try XCTUnwrap((try plist(d)["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(vpn["VPNType"] as? String, "IKEv2")
        let ike = try XCTUnwrap(vpn["IKEv2"] as? [String: Any])
        XCTAssertEqual(ike["RemoteAddress"] as? String, "vpn.example.com")
        XCTAssertEqual(ike["RemoteIdentifier"] as? String, "vpn.example.com")
        XCTAssertEqual(ike["AuthenticationMethod"] as? String, "None")
        XCTAssertEqual(ike["ExtendedAuthEnabled"] as? Int, 1)
        XCTAssertNil(vpn["DNS"])
        XCTAssertNil(vpn["PPP"])
    }

    func testProblems() {
        XCTAssertTrue(l2tp().problems().isEmpty)
        var d = VPNProfileDraft()
        XCTAssertEqual(d.problems().count, 4) // name, server, account, secret
        d = l2tp()
        d.server = "not a host"
        d.dnsServers = "1.1.1.1 dns.google"
        XCTAssertEqual(d.problems().count, 2)
        d = l2tp()
        d.kind = .ikev2
        d.account = ""
        d.sharedSecret = ""
        XCTAssertFalse(d.problems().isEmpty)
    }

    func testProfileIsValidPlistFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vpnguard-test.mobileconfig")
        try l2tp().mobileconfig().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        p.arguments = ["-lint", "-s", url.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }
}

final class WireGuardTests: XCTestCase {
    // RFC 7748 section 6.1: Alice's key pair.
    let rfcPrivate = Data([0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, 0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
                           0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a, 0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a]).base64EncodedString()
    let rfcPublic = Data([0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54, 0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e, 0xf7, 0x5a,
                          0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4, 0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a]).base64EncodedString()

    func testKeys() {
        XCTAssertEqual(WireGuardKey.publicKey(fromPrivate: rfcPrivate), rfcPublic)
        let k = WireGuardKey.generatePrivate()
        XCTAssertTrue(WireGuardKey.isValid(k))
        let raw = WireGuardKey.decode(k)!
        XCTAssertEqual(raw[0] & 7, 0, "clamped")
        XCTAssertEqual(raw[31] & 0xC0, 0x40, "clamped")
        XCTAssertNotNil(WireGuardKey.publicKey(fromPrivate: k))
        XCTAssertEqual(WireGuardKey.hex(rfcPrivate), "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        XCTAssertFalse(WireGuardKey.isValid("abc="))
    }

    func conf(peer: String = "", extraPeer: Bool = false) -> String {
        """
        # home router
        [Interface]
        PrivateKey = \(rfcPrivate)
        Address = 10.8.0.2/32, fd00::2
        DNS = 1.1.1.1, home.lan
        MTU = 1420

        [Peer]
        PublicKey = \(rfcPublic)
        PresharedKey = \(rfcPublic)
        Endpoint = Home.Example.net:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        \(peer)
        \(extraPeer ? "[Peer]\nPublicKey = \(rfcPublic)" : "")
        """
    }

    func testParseConf() throws {
        let parsed = try WireGuardConf.parse(conf(), name: "Home")
        let t = parsed.tunnel
        XCTAssertEqual(t.name, "Home")
        XCTAssertEqual(t.publicKey, rfcPublic)
        XCTAssertEqual(t.addresses, ["10.8.0.2/32", "fd00::2/128"])
        XCTAssertEqual(t.dns, ["1.1.1.1"], "search domains are dropped")
        XCTAssertEqual(t.mtu, 1420)
        XCTAssertEqual(t.endpointHost, "home.example.net")
        XCTAssertEqual(t.endpointPort, 51820)
        XCTAssertTrue(t.isFullTunnel)
        XCTAssertTrue(t.hasPresharedKey)
        XCTAssertEqual(parsed.privateKey, rfcPrivate)
        XCTAssertEqual(parsed.presharedKey, rfcPublic)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try WireGuardConf.parse("hello", name: "x"))
        XCTAssertThrowsError(try WireGuardConf.parse(conf(extraPeer: true), name: "x"))
        XCTAssertThrowsError(try WireGuardConf.parse(conf().replacingOccurrences(of: "Home.Example.net:51820", with: "[::1]:51820"), name: "x"))
        XCTAssertThrowsError(try WireGuardConf.parse(conf(), name: " "), "a name is needed")
    }

    func testEndpointAndCIDR() {
        XCTAssertEqual(WireGuardTunnel.splitEndpoint("203.0.113.10:51820")?.host, "203.0.113.10")
        XCTAssertNil(WireGuardTunnel.splitEndpoint("203.0.113.10"))
        XCTAssertNil(WireGuardTunnel.splitEndpoint("vpn.example.com:0"))
        XCTAssertNil(WireGuardTunnel.splitEndpoint("bad host:51820"))
        XCTAssertTrue(Net.isCIDR("0.0.0.0/0"))
        XCTAssertTrue(Net.isCIDR("::/0"))
        XCTAssertFalse(Net.isCIDR("10.0.0.1/33"))
        XCTAssertFalse(Net.isCIDR("10.0.0.1"))
    }

    func testFirewallAllowsWireGuardServer() throws {
        let t = try WireGuardConf.parse(conf(), name: "Home").tunnel
        var c = GuardConfig(vpnServers: ["203.0.113.10"], wireguard: [t])
        XCTAssertEqual(c.serverHosts, ["203.0.113.10", "home.example.net"])
        XCTAssertEqual(c.allowedIPs, ["203.0.113.10"])
        c.hostIPs["home.example.net"] = ["198.51.100.7"]
        XCTAssertEqual(c.allowedIPs, ["203.0.113.10", "198.51.100.7"])
    }

    func testMikrotikCommand() throws {
        let t = try WireGuardConf.parse(conf(), name: "Home").tunnel
        let cmd = t.mikrotikCommand()
        XCTAssertTrue(cmd.contains("public-key=\"\(rfcPublic)\""))
        XCTAssertTrue(cmd.contains("allowed-address=10.8.0.2/32"))
    }

    func testRuntime() {
        var r = WireGuardRuntime(tunnelID: UUID(), interface: "utun9", startedAt: Date(), lastHandshake: Date(timeIntervalSinceNow: -10))
        XCTAssertTrue(r.isConnected())
        r.lastHandshake = Date(timeIntervalSinceNow: -400)
        XCTAssertFalse(r.isConnected())
        r.interface = nil
        XCTAssertFalse(r.isRunning)
    }

    // MARK: - Who may control the helper

    func testClientTrustTeamRequirement() {
        let r = ClientTrust.requirement(teamID: "ABCDE12345", ownCDHash: nil, pinnedCDHashes: [])
        XCTAssertEqual(r, "anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\" and "
            + "(identifier \"local.vpnguard.app\" or identifier \"local.vpnguard.helper\")")
    }

    func testClientTrustAdHocPinsExactHashes() {
        let own = String(repeating: "a", count: 40)
        let app = "0123456789ABCDEF0123456789abcdef01234567"
        let r = ClientTrust.requirement(teamID: nil, ownCDHash: own, pinnedCDHashes: [app, own])
        XCTAssertEqual(r, "cdhash H\"\(own)\" or cdhash H\"\(app.lowercased())\"")
        XCTAssertFalse(r.contains("identifier"), "ad-hoc builds must not trust identifiers alone")
    }

    func testClientTrustRejectsInjection() {
        let evil = [
            "aaaa\" or always or cdhash H\"",
            String(repeating: "a", count: 39),
            String(repeating: "a", count: 41),
            String(repeating: "g", count: 40),
            "",
        ]
        XCTAssertEqual(ClientTrust.requirement(teamID: nil, ownCDHash: nil, pinnedCDHashes: evil), "never")
        // A bad team ID falls back to hashes, never to a broken team rule.
        XCTAssertEqual(ClientTrust.requirement(teamID: "X\" or always", ownCDHash: nil, pinnedCDHashes: []), "never")
        XCTAssertEqual(ClientTrust.requirement(teamID: "", ownCDHash: nil, pinnedCDHashes: []), "never")
    }

    func testClientPinsKeepOnlyValidHashes() throws {
        let good = String(repeating: "b", count: 40)
        let pins = ClientPins(appPath: "/Applications/VPN Guard.app", cdhashes: [good, "nope", good.uppercased()])
        XCTAssertEqual(pins.validHashes, [good])
        let round = try Wire.decode(ClientPins.self, from: Wire.encode(pins))
        XCTAssertEqual(round.validHashes, [good])
    }

    // MARK: - Logic review fixes (1.1.2)

    private func link(_ iface: String, _ addr: String?, _ router: String, _ mac: String?) -> NetworkLink {
        NetworkLink(interface: iface, displayName: iface == "en0" ? "Wi-Fi" : "USB LAN", address: addr,
                    routerIP: router, routerMAC: mac)
    }

    /// Bug 1: switching VPN must not remove another VPN's server, and hand-typed servers stay.
    func testServerListKeepsAllVPNServersAndManualOnes() {
        let current = ["198.51.100.7", "vpn.example.com"]           // manual + auto from before
        let r = ServerList.merge(current: current, previousAuto: ["vpn.example.com"],
                                 wanted: ["203.0.113.10", "VPN.Example.com.", "home.example.net"])
        XCTAssertEqual(r.list, ["198.51.100.7", "vpn.example.com", "203.0.113.10", "home.example.net"])
        XCTAssertEqual(r.auto, ["203.0.113.10", "vpn.example.com", "home.example.net"])
        // Choosing another VPN only changes the order of `wanted`: nothing is removed or resent.
        let again = ServerList.merge(current: r.list, previousAuto: r.auto,
                                     wanted: ["vpn.example.com", "203.0.113.10", "home.example.net"])
        XCTAssertEqual(again.list, r.list)
    }

    func testServerListDropsServersOfDeletedVPNsAndBadValues() {
        let r = ServerList.merge(current: ["198.51.100.7", "old.example.com", "203.0.113.10"],
                                 previousAuto: ["old.example.com", "203.0.113.10"],
                                 wanted: ["203.0.113.10", "not a host!", "", "1.2.3.4 } pass all"])
        XCTAssertEqual(r.list, ["198.51.100.7", "203.0.113.10"])
        XCTAssertEqual(r.auto, ["203.0.113.10"])
    }

    func testServerListLimitKeepsTheChosenVPN() {
        let manual = (1...16).map { "198.51.100.\($0)" }
        let r = ServerList.merge(current: manual, previousAuto: [], wanted: ["203.0.113.10"])
        XCTAssertEqual(r.list.count, 16)
        XCTAssertTrue(r.list.contains("203.0.113.10"), "the chosen VPN's server must survive the limit")
    }

    /// Bug 1 (helper side): a server that leaves the list keeps its looked-up IP.
    func testHostCacheSurvivesSwitchingAndIsCapped() {
        var c = GuardConfig(vpnServers: ["vpn.example.com"], hostIPs: ["vpn.example.com": ["203.0.113.10"]])
        c.vpnServers = ["198.51.100.20"]          // another VPN chosen
        c.pruneHostCache()
        XCTAssertEqual(c.hostIPs["vpn.example.com"], ["203.0.113.10"])
        XCTAssertEqual(c.allowedIPs, ["198.51.100.20"], "a cached IP is not allowed while unused")
        c.vpnServers = ["vpn.example.com"]        // chosen again while locked: allowed at once
        XCTAssertEqual(c.allowedIPs, ["203.0.113.10"])

        for n in 0..<40 { c.hostIPs["h\(n).example.com"] = ["192.0.2.\(n)"] }
        c.pruneHostCache(keepingAtMost: 32)
        XCTAssertEqual(c.hostIPs.count, 32)
        XCTAssertEqual(c.hostIPs["vpn.example.com"], ["203.0.113.10"], "servers in use are never pruned")
    }

    /// Bug 2: lock mode lets out only root DNS from the helper's port.
    func testLockRulesDNSLookupRule() {
        let rules = PFRules.lockRules(vpnServers: ["203.0.113.10"], routers: ["192.0.2.1"], interfaces: [],
                                      dnsLookupPort: VG.dnsLookupPort)
        XCTAssertTrue(rules.contains("pass out quick inet proto udp from any port 53530 to any port 53 keep state"))
        let dnsLines = rules.split(separator: "\n").filter { $0.contains("port 53 ") || $0.hasSuffix("port 53") }
        XCTAssertEqual(dnsLines.count, 1, "no other DNS may pass")
        XCTAssertFalse(PFRules.lockRules(vpnServers: [], routers: [], interfaces: []).contains("port 53"))
        XCTAssertFalse(PFRules.lockRules(vpnServers: [], routers: [], interfaces: [], dnsLookupPort: 53).contains("port 53 keep"),
                       "a low port is refused")
        let lines = rules.split(separator: "\n").map(String.init)
        XCTAssertLessThan(lines.firstIndex { $0.contains("port 53530") }!, lines.firstIndex { $0.hasPrefix("block return out") }!)
    }

    /// The generated rules must be valid pf syntax (macOS's own parser, no root needed).
    func testLockRulesParseWithPfctl() throws {
        for refuse in [true, false] {
        let rules = PFRules.lockRules(vpnServers: ["203.0.113.10", "198.51.100.20"], routers: ["192.0.2.1"],
                                      interfaces: ["bridge100", "vmenet0"], dnsLookupPort: VG.dnsLookupPort, refuse: refuse)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        p.arguments = ["-n", "-f", "-"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        try p.run()
        input.fileHandleForWriting.write(Data(rules.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0, "pfctl rejected the rules:\n\(text)\n\(rules)")
        }
    }

    /// Bug 4: a router address that stays unknown still starts the VPN, after a short grace.
    func testAutoVPNStartsWhenRouterStaysUnknown() {
        XCTAssertTrue(AutoVPN.wantsVPN(mode: .locked, reason: .untrusted, resolvingFor: 0))
        XCTAssertFalse(AutoVPN.wantsVPN(mode: .locked, reason: .resolving, resolvingFor: 1))
        XCTAssertTrue(AutoVPN.wantsVPN(mode: .locked, reason: .resolving, resolvingFor: 5))
        XCTAssertFalse(AutoVPN.wantsVPN(mode: .locked, reason: .noNetwork, resolvingFor: 60))
        XCTAssertFalse(AutoVPN.wantsVPN(mode: .open, reason: .trusted, resolvingFor: 0))
        XCTAssertFalse(AutoVPN.wantsVPN(mode: .open, reason: .disabled, resolvingFor: 0))
    }

    /// Bug 6: one router seen over Wi-Fi and a cable is one trusted entry.
    func testTrustOneEntryPerRouter() {
        let mac = "aa:bb:cc:00:11:22"
        let same = TrustedNetwork.newEntries(name: "Office", candidates: [
            link("en0", "192.0.2.43", "192.0.2.1", mac), link("en7", "192.0.2.46", "192.0.2.1", "AA:BB:CC:00:11:22"),
        ])
        XCTAssertEqual(same.map(\.name), ["Office"])
        XCTAssertEqual(same.first?.routerMAC, mac)
        let two = TrustedNetwork.newEntries(name: "Office", candidates: [
            link("en0", "192.0.2.43", "192.0.2.1", mac), link("en7", "198.51.100.5", "198.51.100.1", "aa:bb:cc:00:11:33"),
            link("en8", "203.0.113.5", "203.0.113.1", nil),
        ])
        XCTAssertEqual(two.map(\.name), ["Office (Wi-Fi)", "Office (USB LAN)"])
    }

    /// Bug 7: restart a PPP VPN only when the network it used is gone and another one is up.
    func testPPPRestartWhenNetworkMovedAway() {
        let hotspot = link("en0", "172.20.10.6", "172.20.10.1", "aa:bb:cc:00:00:01")
        let on = Set([AutoVPN.linkKey(hotspot)])
        XCTAssertFalse(AutoVPN.networkMovedAway(connectedOn: on, links: [hotspot]))
        XCTAssertFalse(AutoVPN.networkMovedAway(connectedOn: on, links: []), "no network: wait, it may come back")
        XCTAssertFalse(AutoVPN.networkMovedAway(connectedOn: on, links: [hotspot, link("en7", "192.0.2.46", "192.0.2.1", nil)]))
        XCTAssertTrue(AutoVPN.networkMovedAway(connectedOn: on, links: [link("en0", "172.20.10.9", "172.20.10.1", "aa:bb:cc:00:00:01")]),
                      "new address on the same Wi-Fi: the tunnel is dead")
        XCTAssertTrue(AutoVPN.networkMovedAway(connectedOn: on, links: [link("en0", "192.0.2.43", "192.0.2.1", nil)]))
        XCTAssertFalse(AutoVPN.networkMovedAway(connectedOn: [], links: [hotspot]))
        XCTAssertTrue(AutoVPN.isPPP(kind: "L2TP"))
        XCTAssertFalse(AutoVPN.isPPP(kind: "VPN"), "IKEv2 moves to a new network by itself")
    }

    // MARK: - Network loss and change (1.1.3)

    /// #1: a pause belongs to the place where it started.
    func testPauseEndsOnAnotherNetwork() {
        let hotel = link("en0", "192.0.2.43", "192.0.2.1", "aa:bb:cc:00:00:01")
        let on = PausedNetwork(links: [hotel])
        XCTAssertTrue(on.covers([hotel]))
        XCTAssertTrue(on.covers([]), "no network (Wi-Fi blip, sleep) keeps the pause")
        XCTAssertTrue(on.covers([link("en0", "192.0.2.77", "192.0.2.1", "AA:BB:CC:00:00:01")]), "new address, same router")
        XCTAssertFalse(on.covers([link("en0", "192.0.2.43", "192.0.2.1", "aa:bb:cc:00:00:99")]),
                       "a cafe with the same router IP but another router")
        XCTAssertFalse(on.covers([hotel, link("en7", "172.20.10.2", "172.20.10.1", "aa:bb:cc:00:00:02")]),
                       "a second, new network (iPhone USB) ends it too")
        XCTAssertTrue(on.covers([link("en0", "192.0.2.43", "192.0.2.1", nil)]), "router not checked yet, same IP")
        XCTAssertFalse(on.covers([link("en0", "198.51.100.4", "198.51.100.1", nil)]), "router not checked yet, other IP")
    }

    func testOldConfigWithoutPausedOnStillLoads() throws {
        let json = #"{"enabled":true,"vpnServers":[],"trusted":[],"pausedUntil":800000000}"#
        let c = try JSONDecoder().decode(GuardConfig.self, from: Data(json.utf8))
        XCTAssertNil(c.pausedOn)
        XCTAssertNotNil(c.pausedUntil)
    }

    /// #4: a Wi-Fi blip or a short sleep is not a new place.
    func testSameNetworkAfterBlip() {
        let office = "en0=aa:bb:cc:00:00:01"
        XCTAssertFalse(AutoVPN.isNewNetwork(key: "", lastKey: office, goneFor: nil))
        XCTAssertFalse(AutoVPN.isNewNetwork(key: office, lastKey: office, goneFor: 4))
        XCTAssertTrue(AutoVPN.isNewNetwork(key: office, lastKey: office, goneFor: 3600), "away for an hour")
        XCTAssertTrue(AutoVPN.isNewNetwork(key: "en0=aa:bb:cc:00:00:02", lastKey: office, goneFor: 4))
        XCTAssertTrue(AutoVPN.isNewNetwork(key: office, lastKey: "", goneFor: nil), "first network after launch")
    }

    /// #3: WireGuard's server route follows the network macOS really uses.
    func testPrimaryDefaultRoute() {
        let normal = """
        Routing tables

        Internet:
        Destination        Gateway            Flags               Netif Expire
        default            192.0.2.1          UGScg                 en7
        default            198.51.100.1       UGScIg                en0
        default            link#27            UCSIg           bridge100      !
        """
        XCTAssertEqual(Routes.primaryDefault(netstat: normal)?.interface, "en7", "not en0 just because it sorts first")
        XCTAssertEqual(Routes.primaryDefault(netstat: normal)?.gateway, "192.0.2.1")
        let wireGuardOn = """
        Destination        Gateway            Flags               Netif Expire
        default            10.8.0.2           UGSc                utun9
        default            192.0.2.1          UGScIg                en7
        """
        XCTAssertNil(Routes.primaryDefault(netstat: wireGuardOn), "tunnel and scoped routes are not the answer")
        XCTAssertNil(Routes.primaryDefault(netstat: ""))
    }

    /// #6: which card a VPN server is reached through.
    func testRouteGetInterface() {
        let out = """
           route to: 203.0.113.10
        destination: 203.0.113.10
            gateway: 192.0.2.1
          interface: en7
              flags: <UP,GATEWAY,HOST,DONE,STATIC>
        """
        XCTAssertEqual(Routes.interface(routeGet: out), "en7")
        XCTAssertNil(Routes.interface(routeGet: "  interface: en0; rm -rf /"))
        XCTAssertNil(Routes.interface(routeGet: "route: writing to routing socket: not in table"))
    }

    /// #7: during "no network / checking the router" the lock drops silently.
    func testLockRulesDropVariant() {
        let drop = PFRules.lockRules(vpnServers: [], routers: [], interfaces: [], refuse: false)
        XCTAssertTrue(drop.contains("block drop out quick all"))
        XCTAssertFalse(drop.contains("block return"))
        XCTAssertTrue(PFRules.lockRules(vpnServers: [], routers: [], interfaces: []).contains("block return out quick all"))
    }

    // MARK: - Two networks at once (1.2.0)

    func testLockRulesOpenOnlyTrustedCards() {
        let rules = PFRules.lockRules(vpnServers: ["203.0.113.10"], routers: ["192.0.2.1", "172.20.10.1"],
                                      interfaces: [], openInterfaces: ["en0", "en0", "utun3", "lo0", "en0 } pass all"])
        XCTAssertTrue(rules.contains("pass quick on { en0 } all no state"))
        XCTAssertFalse(rules.contains("pass all"), "a bad interface name never reaches pf")
        XCTAssertFalse(rules.contains("on { utun3 }"))
        let lines = rules.split(separator: "\n").map(String.init)
        XCTAssertLessThan(lines.firstIndex(of: "pass quick on { en0 } all no state")!,
                          lines.firstIndex { $0.hasPrefix("block return out") }!)
        XCTAssertFalse(PFRules.lockRules(vpnServers: [], routers: [], interfaces: []).contains("on { en0 }"))
    }

    func testMixedRulesParseWithPfctl() throws {
        let rules = PFRules.lockRules(vpnServers: ["203.0.113.10"], routers: ["192.0.2.1"], interfaces: ["bridge100"],
                                      dnsLookupPort: VG.dnsLookupPort, openInterfaces: ["en0", "en5"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        p.arguments = ["-n", "-f", "-"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        try p.run()
        input.fileHandleForWriting.write(Data(rules.utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testAutoVPNWithTwoNetworks() {
        XCTAssertFalse(AutoVPN.wantsVPN(mode: .locked, reason: .mixed, resolvingFor: 0, primaryTrusted: true),
                       "the Mac uses the office: no VPN")
        XCTAssertTrue(AutoVPN.wantsVPN(mode: .locked, reason: .mixed, resolvingFor: 0, primaryTrusted: false),
                      "the Mac uses the iPhone: VPN")
    }

    func testTrustPickDefaultsAndHotspots() {
        let wifi = link("en0", "192.0.2.43", "192.0.2.1", "aa:bb:cc:00:00:01")
        let phone = link("en7", "172.20.10.2", "172.20.10.1", "aa:bb:cc:00:00:02")
        XCTAssertTrue(TrustPick.isPhoneHotspot(phone))
        XCTAssertTrue(TrustPick.isPhoneHotspot(link("en0", "192.168.43.7", "192.168.43.1", nil)), "Android")
        XCTAssertFalse(TrustPick.isPhoneHotspot(wifi))

        XCTAssertFalse(TrustPick.needsPicker([wifi]), "one ordinary network: the simple dialog")
        XCTAssertTrue(TrustPick.needsPicker([phone]), "a hotspot always gets the warning")
        XCTAssertTrue(TrustPick.needsPicker([wifi, link("en5", "198.51.100.4", "198.51.100.1", "aa:bb:cc:00:00:03")]))

        XCTAssertEqual(TrustPick.defaultTicks([wifi, phone], primaryInterface: "en0"), ["aa:bb:cc:00:00:01"])
        XCTAssertEqual(TrustPick.defaultTicks([wifi, phone], primaryInterface: "en7"), [], "a hotspot is never ticked for you")
        XCTAssertEqual(TrustPick.defaultTicks([phone], primaryInterface: "en0"), [], "the network in use is trusted already")
    }

    // MARK: - NAT64 networks (1.2.1)

    /// RFC 6052 section 2.4 examples (192.0.2.33 in each prefix length).
    func testNAT64SynthesisMatchesRFC6052() {
        let v4 = "192.0.2.33"
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "2001:db8::/32"), "2001:db8:c000:221::")
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "2001:db8:100::/40"), "2001:db8:1c0:2:21::")
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "2001:db8:122::/48"), "2001:db8:122:c000:2:2100::")
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "2001:db8:122:300::/56"), "2001:db8:122:3c0:0:221::")
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "2001:db8:122:344::/64"), "2001:db8:122:344:c0:2:2100:0")
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "2001:db8:122:344::/96"), "2001:db8:122:344::c000:221")
        XCTAssertEqual(NAT64.synthesize(ipv4: v4, prefix: "64:ff9b::/96"), "64:ff9b::c000:221", "the well-known prefix")
    }

    func testNAT64RejectsBadInput() {
        XCTAssertNil(NAT64.synthesize(ipv4: "192.0.2.33", prefix: "64:ff9b::/80"), "not an RFC 6052 length")
        XCTAssertNil(NAT64.synthesize(ipv4: "192.0.2.33", prefix: "64:ff9b::"))
        XCTAssertNil(NAT64.synthesize(ipv4: "vpn.example.com", prefix: "64:ff9b::/96"))
        XCTAssertNil(NAT64.synthesize(ipv4: "192.0.2.33", prefix: "64:ff9b::/96; pass all"))
        XCTAssertEqual(NAT64.serverAddresses(["192.0.2.33", "198.51.100.20"], prefixes: ["64:ff9b::/96"]),
                       ["64:ff9b::c000:221", "64:ff9b::c633:6414"])
    }

    func testLockRulesAllowVPNServerOverNAT64Only() {
        let six = NAT64.serverAddresses(["203.0.113.10"], prefixes: ["64:ff9b::/96"])
        let rules = PFRules.lockRules(vpnServers: ["203.0.113.10"], routers: ["172.20.10.1"], interfaces: [],
                                      vpnServers6: six + ["not-an-address } pass all"])
        XCTAssertTrue(rules.contains("pass out quick inet6 from any to { 64:ff9b::cb00:710a } no state"))
        XCTAssertTrue(rules.contains("pass in quick inet6 from { 64:ff9b::cb00:710a } to any no state"))
        XCTAssertTrue(rules.contains("icmp6-type { routersol routeradv neighbrsol neighbradv }"))
        XCTAssertFalse(rules.contains("pass all"))
        XCTAssertFalse(PFRules.lockRules(vpnServers: ["203.0.113.10"], routers: [], interfaces: []).contains("inet6"),
                       "without NAT64 all IPv6 stays blocked")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        p.arguments = ["-n", "-f", "-"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        try? p.run()
        input.fileHandleForWriting.write(Data(rules.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testShortCardNames() {
        XCTAssertEqual(NetworkLink(interface: "en7", displayName: "USB 10/100/1000 LAN", routerIP: "192.0.2.1").label, "USB LAN")
        XCTAssertEqual(NetworkLink(interface: "en8", displayName: "USB 10/100 LAN", routerIP: "192.0.2.1").label, "USB LAN")
        XCTAssertEqual(NetworkLink(interface: "en0", displayName: "Wi-Fi", routerIP: "192.0.2.1").label, "Wi-Fi")
        XCTAssertEqual(NetworkLink(interface: "en9", displayName: "iPhone USB", routerIP: "172.20.10.1").label, "iPhone USB")
        XCTAssertEqual(NetworkLink(interface: "en5", routerIP: "192.0.2.1").label, "en5")
    }

    func testOwnVPNStopsWhenProtectionIsOffOrPaused() {
        XCTAssertTrue(AutoVPN.shouldStopOwnVPN(reason: .disabled))
        XCTAssertTrue(AutoVPN.shouldStopOwnVPN(reason: .paused))
        for r in [GuardReason.untrusted, .mixed, .resolving, .noNetwork, .trusted] {
            XCTAssertFalse(AutoVPN.shouldStopOwnVPN(reason: r), "\(r)")
        }
    }

    // MARK: - WireGuard files made before they were ready (1.2.3)

    func testUsableHostAddresses() {
        for ok in ["10.8.0.2", "192.0.2.222", "100.64.0.7", "fd00::2", "2001:db8::5"] {
            XCTAssertTrue(Net.isUsableHostAddress(ok), ok)
        }
        for bad in ["0.0.0.0", "0.1.2.3", "127.0.0.1", "224.0.0.1", "255.255.255.255", "::", "::1", "ff02::1", "nope"] {
            XCTAssertFalse(Net.isUsableHostAddress(bad), bad)
        }
    }

    func testWireGuardFileWithZeroAddressIsRefused() throws {
        let conf = """
        [Interface]
        PrivateKey = \(WireGuardKey.generatePrivate())
        Address = 0.0.0.0/32
        DNS = 1.1.1.1

        [Peer]
        PublicKey = \(WireGuardKey.publicKey(fromPrivate: WireGuardKey.generatePrivate())!)
        AllowedIPs = 0.0.0.0/24
        Endpoint = vpn.example.com:51820
        """
        // Import refuses the half-made file and says why (the first problem: the address).
        XCTAssertThrowsError(try WireGuardConf.parse(conf, name: "Office")) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("0.0.0.0/32") && text.contains("download it again"), text)
        }
        // With a real address, the odd AllowedIPs is the next thing it explains.
        let onlyAllowed = conf.replacingOccurrences(of: "Address = 0.0.0.0/32", with: "Address = 192.0.2.222/32")
        XCTAssertThrowsError(try WireGuardConf.parse(onlyAllowed, name: "Office")) { error in
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("0.0.0.0/24") && text.contains("0.0.0.0/0"), text)
        }

        let good = conf.replacingOccurrences(of: "Address = 0.0.0.0/32", with: "Address = 192.0.2.222/32")
            .replacingOccurrences(of: "AllowedIPs = 0.0.0.0/24", with: "AllowedIPs = 192.0.2.0/24")
        XCTAssertEqual(try WireGuardConf.parse(good, name: "Office").tunnel.problems(), [])
    }

    // MARK: - VPN that only carries some addresses (1.2.3)

    func testCIDRContains() {
        XCTAssertTrue(Net.cidrContains("192.0.2.0/24", ip: "192.0.2.1"))
        XCTAssertFalse(Net.cidrContains("192.0.2.0/24", ip: "192.0.3.1"))
        XCTAssertTrue(Net.cidrContains("0.0.0.0/0", ip: "203.0.113.9"))
        XCTAssertTrue(Net.cidrContains("10.0.0.0/8", ip: "10.200.1.1"))
        XCTAssertFalse(Net.cidrContains("bad", ip: "10.0.0.1"))
        XCTAssertFalse(Net.cidrContains("192.0.2.0/33", ip: "192.0.2.1"))
    }

    func testTrustedNetworkCarriedByRanges() {
        let office = TrustedNetwork(name: "Office", routerMAC: "aa:bb:cc:00:00:01", routerIP: "192.0.2.1")
        let c = GuardConfig(enabled: true, trusted: [office])
        XCTAssertEqual(c.trustedNetworkName(carriedBy: ["192.0.2.0/24"]), "Office")
        XCTAssertNil(c.trustedNetworkName(carriedBy: ["198.51.100.0/24"]))
    }

    // MARK: - Rename a VPN (1.2.3)

    func testDisplayNameClean() {
        XCTAssertEqual(DisplayName.clean("  Office VPN  "), "Office VPN")
        XCTAssertEqual(DisplayName.clean("Office\nVPN"), "OfficeVPN")
        XCTAssertEqual(DisplayName.clean("Office\u{0007}VPN"), "OfficeVPN")
        XCTAssertNil(DisplayName.clean("   "))
        XCTAssertNil(DisplayName.clean("\n\t"))
        XCTAssertEqual(DisplayName.clean(String(repeating: "a", count: 100))?.count, 64)
    }

    func testServiceIDCheck() {
        XCTAssertTrue(Net.isServiceID("5F1D2C3A-9B7E-4A60-8D21-0C4E6F8A1B2D"))
        XCTAssertFalse(Net.isServiceID("wg:5F1D2C3A-9B7E-4A60-8D21-0C4E6F8A1B2D"))
        XCTAssertFalse(Net.isServiceID("../NetworkServices"))
        XCTAssertFalse(Net.isServiceID(""))
    }

    func testRenameCommandsRoundTrip() throws {
        let id = UUID()
        for c in [HelperCommand.wgRename(id: id, name: "Office tunnel"),
                  .renameMacVPN(serviceID: "5F1D2C3A-9B7E-4A60-8D21-0C4E6F8A1B2D", name: "Office VPN")] {
            let back = try JSONDecoder().decode(HelperCommand.self, from: JSONEncoder().encode(c))
            XCTAssertEqual(String(describing: back), String(describing: c))
        }
    }

    // MARK: - Why the VPN failed, backup VPN, notifications, protection test (1.3.0)

    private let utc = TimeZone(identifier: "UTC")!

    /// Lines as macOS writes them to /var/log/ppp.log (example data).
    private func pppLog(_ lines: [String], at clock: String = "15:10") -> String {
        lines.enumerated().map { "Thu Nov 26 \(clock):\(String(format: "%02d", 30 + $0.offset)) 2026 : \($0.element)" }
            .joined(separator: "\n")
    }

    func testPPPLogLoginRefused() {
        let log = pppLog([
            "L2TP connecting to server 'vpn.example.com' (192.0.2.10)...",
            "IPSec connection established",
            "L2TP connection established.",
            "rcvd [CHAP Challenge id=0x1 <00>, name = \"alex\"]",
            "rcvd [CHAP Failure id=0x1 \"E=691 R=1 C=00 V=0 M=Good luck!\"]",
            "MS-CHAP authentication failed: Good luck!",
            "Connection terminated.",
        ])
        XCTAssertEqual(PPPLog.lastFailure(in: log, server: "vpn.example.com", timeZone: utc), .loginRefused(code: 691))
        XCTAssertEqual(PPPLog.lastFailure(in: log, timeZone: utc), .loginRefused(code: 691))
        // The last attempt in the log belongs to another VPN: say nothing.
        XCTAssertNil(PPPLog.lastFailure(in: log, server: "other.example.net", timeZone: utc))
        XCTAssertEqual(PPPLog.lastFailure(in: log.replacingOccurrences(of: "E=691", with: "E=647"), timeZone: utc),
                       .loginRefused(code: 647))
    }

    func testPPPLogServerDidNotAnswerAndSecret() {
        let noAnswer = pppLog([
            "L2TP connecting to server 'vpn.example.com' (192.0.2.10)...",
            "IPSec connection started",
            "IPSec phase 1 client started",
            "IPSec connection failed",
        ])
        XCTAssertEqual(PPPLog.lastFailure(in: noAnswer, timeZone: utc), .noAnswer)
        let secret = pppLog([
            "L2TP connecting to server 'vpn.example.com' (192.0.2.10)...",
            "IPSec phase 1 client started",
            "IPSec phase 1 server replied",
            "IPSec connection failed",
        ])
        XCTAssertEqual(PPPLog.lastFailure(in: secret, timeZone: utc), .secretRefused)
    }

    func testPPPLogOnlyLooksAtThisAttempt() {
        // An older refused login, then an attempt that worked: no failure.
        let old = pppLog(["L2TP connecting to server 'vpn.example.com' (192.0.2.10)...",
                          "MS-CHAP authentication failed: Good luck!"], at: "15:10")
        let good = pppLog(["L2TP connecting to server 'vpn.example.com' (192.0.2.10)...",
                           "L2TP connection established.", "ipcp: up"], at: "15:49")
        XCTAssertNil(PPPLog.lastFailure(in: old + "\n" + good, timeZone: utc))
        // With a start time: lines before it do not count, even without a "connecting" line after it.
        var c = Calendar(identifier: .gregorian); c.timeZone = utc
        let start = c.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15, minute: 40))!
        XCTAssertNil(PPPLog.lastFailure(in: old, since: start, timeZone: utc))
        XCTAssertEqual(PPPLog.lastFailure(in: old, since: start.addingTimeInterval(-3600), timeZone: utc),
                       .loginRefused(code: nil))
        // Connected, then the server went silent.
        let lost = pppLog(["L2TP connecting to server 'vpn.example.com' (192.0.2.10)...", "ipcp: up",
                           "No response to 3 echo-requests", "Connection terminated."])
        XCTAssertEqual(PPPLog.lastFailure(in: lost, timeZone: utc), .connectionLost)
        // A user disconnect is not a failure.
        let stopped = pppLog(["L2TP connecting to server 'vpn.example.com' (192.0.2.10)...", "ipcp: up",
                              "Terminating on signal 15.", "Connection terminated."])
        XCTAssertNil(PPPLog.lastFailure(in: stopped, timeZone: utc))
        XCTAssertNil(PPPLog.lastFailure(in: "", timeZone: utc))
    }

    func testPPPLogDateWithOneDigitDay() {
        var c = Calendar(identifier: .gregorian); c.timeZone = utc
        XCTAssertEqual(PPPLog.date(of: "Thu Nov  5 09:01:02 2026 : ipcp: up", timeZone: utc),
                       c.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 1, second: 2)))
        XCTAssertNil(PPPLog.date(of: "no date here", timeZone: utc))
    }

    func testVPNFailureWords() {
        XCTAssertEqual(VPNFailure.loginRefused(code: 691).label, "Login refused")
        XCTAssertEqual(VPNFailure.loginRefused(code: 691).sentence(vpn: "Office VPN"),
                       "Office VPN could not connect: the server refused the login. The account may be in use on another device.")
        XCTAssertEqual(VPNFailure.loginRefused(code: 648).brief(vpn: "Office VPN"),
                       "Office VPN could not connect: the password has expired.")
        XCTAssertTrue(VPNFailure.loginRefused(code: 691).explanation.contains("(error 691)"))
        XCTAssertEqual(VPNFailure.unknown.brief(vpn: "Office VPN"), "Office VPN could not connect.")
        XCTAssertEqual(VPNFailure.message("The key is missing.").sentence(vpn: "Home"), "Home could not connect. The key is missing.")
        XCTAssertEqual(VPNFailure.from(pppLastCause: 19), .loginRefused(code: nil))
        XCTAssertNil(VPNFailure.from(pppLastCause: 5))   // the user stopped it
    }

    func testBackupVPNOrder() {
        let all = ["main", "b1", "b2"]
        XCTAssertEqual(BackupVPN.next(main: "main", failed: ["main"], candidates: all), "b1")
        XCTAssertEqual(BackupVPN.next(main: "main", failed: ["main", "b1"], candidates: all), "b2")
        XCTAssertNil(BackupVPN.next(main: "main", failed: ["main", "b1", "b2"], candidates: all))
        XCTAssertNil(BackupVPN.next(main: "main", failed: ["main"], candidates: ["main"]))
    }

    func testNoticesOnlyWhenNeeded() {
        // Joined a café, VPN up after a few seconds: silent.
        XCTAssertNil(Notices.decide(situation: .blocked, blockedFor: 6, failedTries: 0, lastSent: nil))
        XCTAssertNil(Notices.decide(situation: .protected, blockedFor: 0, failedTries: 0, lastSent: nil))
        // Blocked for a while, or three failed tries: tell once.
        XCTAssertEqual(Notices.decide(situation: .blocked, blockedFor: 21, failedTries: 0, lastSent: nil), .blocked)
        XCTAssertEqual(Notices.decide(situation: .blocked, blockedFor: 4, failedTries: 3, lastSent: nil), .blocked)
        XCTAssertNil(Notices.decide(situation: .blocked, blockedFor: 300, failedTries: 9, lastSent: .blocked))
        // Backup in use, then the good news once.
        XCTAssertEqual(Notices.decide(situation: .backup, blockedFor: 0, failedTries: 0, lastSent: .blocked), .backup)
        XCTAssertNil(Notices.decide(situation: .backup, blockedFor: 0, failedTries: 0, lastSent: .backup))
        XCTAssertEqual(Notices.decide(situation: .protected, blockedFor: 0, failedTries: 0, lastSent: .blocked), .protectedAgain)
        XCTAssertNil(Notices.decide(situation: .protected, blockedFor: 0, failedTries: 0, lastSent: .protectedAgain))
        XCTAssertNil(Notices.decide(situation: .quiet, blockedFor: 900, failedTries: 9, lastSent: nil))

        XCTAssertEqual(Notices.text(.blocked, vpn: "Office VPN", reason: .loginRefused(code: 691)).body,
                       "Office VPN could not connect: the server refused the login.")
        XCTAssertEqual(Notices.text(.backup, vpn: "Home VPN", main: "Office VPN").body,
                       "Office VPN could not connect. Home VPN is used on this network.")
        XCTAssertEqual(Notices.text(.protectedAgain, vpn: "Office VPN").title, "Protected again")
    }

    func testLeakReport() {
        let wifi = LeakProbe(interface: "en0", label: "Wi-Fi", internetGotOut: false, dnsGotOut: false, ipv6GotOut: nil)
        let good = LeakTest.report(rulesActive: true, probes: [wifi], vpnName: "Office VPN", vpnConnected: true, viaVPNWorks: true)
        XCTAssertEqual(good.verdict, .noLeaks)
        XCTAssertEqual(good.subtitle, "Tested on Wi-Fi (not trusted) with Office VPN")
        XCTAssertEqual(good.checks.map(\.result), [.pass, .pass, .pass, .skipped, .pass])

        var leaky = wifi
        leaky.internetGotOut = true
        let bad = LeakTest.report(rulesActive: true, probes: [leaky], vpnName: "Office VPN", vpnConnected: true, viaVPNWorks: true)
        XCTAssertEqual(bad.verdict, .leak)
        XCTAssertEqual(bad.checks.first { $0.id == "internet" }?.result, .fail)

        var v6 = wifi
        v6.ipv6GotOut = true
        XCTAssertEqual(LeakTest.report(rulesActive: true, probes: [v6], vpnName: nil, vpnConnected: false, viaVPNWorks: nil).verdict, .leak)

        // Blocked, VPN off: nothing got out, and that is a pass.
        let blocked = LeakTest.report(rulesActive: true, probes: [wifi], vpnName: "Office VPN", vpnConnected: false, viaVPNWorks: nil)
        XCTAssertEqual(blocked.verdict, .noLeaks)
        XCTAssertEqual(blocked.checks.last?.result, .skipped)
        // A probe that could not run is not a pass.
        var unknown = wifi
        unknown.internetGotOut = nil
        XCTAssertEqual(LeakTest.report(rulesActive: true, probes: [unknown], vpnName: nil, vpnConnected: false, viaVPNWorks: nil)
            .checks.first { $0.id == "internet" }?.result, .skipped)
        XCTAssertEqual(LeakTest.report(rulesActive: false, probes: [wifi], vpnName: nil, vpnConnected: false, viaVPNWorks: nil).verdict, .leak)

        XCTAssertNil(LeakTest.withoutProbes(reason: .untrusted, trustedNames: ""))
        XCTAssertNil(LeakTest.withoutProbes(reason: .mixed, trustedNames: "Office"))
        XCTAssertEqual(LeakTest.withoutProbes(reason: .trusted, trustedNames: "Office")?.verdict, .nothingToTest)
        XCTAssertEqual(LeakTest.withoutProbes(reason: .trusted, trustedNames: "Office")?.subtitle, "You are at Office, a trusted network")
        XCTAssertEqual(LeakTest.withoutProbes(reason: .disabled, trustedNames: "")?.verdict, .notOn)
    }
}

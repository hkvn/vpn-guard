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

    func testOneUntrustedCardLocksEverything() {
        let c = GuardConfig(enabled: true, trusted: [office])
        let links = [link(office.routerMAC, trusted: "Office"), link("cc:cc:cc:cc:cc:cc", ifname: "en7")]
        let d = Policy.decide(config: c, links: links, now: now)
        XCTAssertEqual(d.mode, .locked)
        XCTAssertEqual(d.reason, .untrusted)
    }

    func testTrustedPlusUnknownStillLocks() {
        let c = GuardConfig(enabled: true, trusted: [office])
        let links = [link(office.routerMAC, trusted: "Office"), link(nil, ifname: "en7")]
        XCTAssertEqual(Policy.decide(config: c, links: links, now: now).mode, .locked)
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
}

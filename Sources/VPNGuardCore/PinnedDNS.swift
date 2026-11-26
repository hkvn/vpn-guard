import Foundation

/// A tiny DNS answerer for the VPN server names only.
///
/// While locked, normal DNS is blocked (it would leave the Mac outside the VPN). But a VPN set up
/// with a host name (e.g. vpn.example.com) must still find its server. So the helper answers
/// those names itself on 127.0.0.1, with the last IP it got from real DNS, and a file in
/// /etc/resolver sends only those names there. Nothing leaves the Mac.
public enum PinnedDNS {
    public static let port: UInt16 = 53535
    /// First line of every /etc/resolver file we own.
    public static let marker = "# VPN Guard"

    public static var resolverFileContent: String {
        "\(marker): this name is answered by VPN Guard on this Mac, so the VPN can connect while DNS is blocked.\nnameserver 127.0.0.1\nport \(port)\n"
    }

    /// The reply to one DNS query packet, or nil if it is not a query we should answer.
    /// Known name + type A: the pinned IPs. Known name + other type: no data. Other name: NXDOMAIN.
    public static func reply(to q: [UInt8], pins: [String: [String]]) -> [UInt8]? {
        guard q.count >= 12, q.count <= 4096 else { return nil }
        let flags = UInt16(q[2]) << 8 | UInt16(q[3])
        guard flags & 0x8000 == 0 else { return nil } // a response, not a query
        let opcode = (flags >> 11) & 0xF
        let qdcount = UInt16(q[4]) << 8 | UInt16(q[5])

        // Question name: plain labels (queries do not use compression).
        var i = 12
        var labels: [String] = []
        while true {
            guard i < q.count else { return nil }
            let len = Int(q[i])
            if len == 0 { i += 1; break }
            guard len < 64, i + 1 + len <= q.count, labels.count < 127 else { return nil }
            labels.append(String(decoding: q[(i + 1)..<(i + 1 + len)], as: UTF8.self).lowercased())
            i += 1 + len
        }
        guard i + 4 <= q.count else { return nil }
        let qtype = UInt16(q[i]) << 8 | UInt16(q[i + 1])
        let qclass = UInt16(q[i + 2]) << 8 | UInt16(q[i + 3])
        let questionEnd = i + 4
        let name = labels.joined(separator: ".")

        var rcode: UInt16 = 0
        var answers: [[UInt8]] = []
        if opcode != 0 || qdcount != 1 {
            rcode = 4 // not implemented
        } else if let ips = pins[name] {
            if (qtype == 1 || qtype == 255) && (qclass == 1 || qclass == 255) {
                for ip in ips {
                    guard let b = ipv4Bytes(ip) else { continue }
                    // name = pointer to the question, type A, class IN, TTL 30 s, 4 bytes
                    answers.append([0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4] + b)
                }
            }
        } else {
            rcode = 3 // no such name
        }

        let withQuestion = opcode == 0 && qdcount == 1
        let outFlags: UInt16 = 0x8000 | 0x0400 | (flags & 0x0100) | rcode // QR, AA, copy RD
        var r: [UInt8] = [q[0], q[1], UInt8(outFlags >> 8), UInt8(outFlags & 0xFF)]
        r += [0, withQuestion ? 1 : 0, UInt8(answers.count >> 8), UInt8(answers.count & 0xFF), 0, 0, 0, 0]
        if withQuestion {
            r += q[12..<questionEnd]
            for a in answers { r += a }
        }
        return r
    }

    static func ipv4Bytes(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr.s_addr) { Array($0) } // already network order
    }
}

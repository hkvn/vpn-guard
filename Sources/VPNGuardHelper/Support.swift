import Foundation
import os
import VPNGuardCore

enum Log {
    private static let logger = Logger(subsystem: VG.logSubsystem, category: "helper")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Goes to the unified log and to stderr (launchd sends stderr to /var/log/vpnguard.log).
    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(stamp.string(from: Date())) \(message)\n".utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("\(stamp.string(from: Date())) ERROR \(message)\n".utf8))
    }
}

struct ShellResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// Runs a program directly (no shell). stdout and stderr are merged into one pipe,
    /// so reading to EOF before waiting cannot deadlock.
    @discardableResult
    static func run(_ path: String, _ args: [String], input: String? = nil) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe = input == nil ? nil : Pipe()
        p.standardInput = inPipe ?? FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ShellResult(status: -1, output: "\(error)")
        }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

struct ConfigStore {
    func load() -> GuardConfig {
        guard let data = FileManager.default.contents(atPath: VG.configPath) else { return GuardConfig() }
        do {
            return try Wire.decode(GuardConfig.self, from: data)
        } catch {
            Log.error("Config file is broken, using defaults: \(error)")
            return GuardConfig()
        }
    }

    func save(_ config: GuardConfig) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: VG.configDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        try Wire.encode(config).write(to: URL(fileURLWithPath: VG.configPath), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: VG.configPath)
    }
}

/// Looks up VPN server host names. `dig` asks the DNS servers directly and ignores /etc/resolver,
/// so we always get the real answer, not our own pinned one. While locked with the VPN down,
/// the query is blocked by pf (nothing leaks) and we keep the last good answer.
enum DNS {
    /// Asks the DNS servers directly (not our own answerer). The fixed source port is the one lock
    /// mode lets out for root (`VG.dnsLookupPort`), so this works while everything else is blocked.
    /// `fixedPortOnly`: while locked only the fixed port can get out, so don't try another one.
    static func lookup(_ host: String, fixedPortOnly: Bool) -> (ips: [String], problem: String?) {
        guard Net.isHostName(host) else { return ([], "not a host name") }
        let first = query(host, ["-b", "0.0.0.0#\(VG.dnsLookupPort)"])
        if !first.ips.isEmpty || fixedPortOnly { return first }
        // Port busy, or no answer: one more try from any port (fine while not locked).
        let second = query(host, [])
        return second.ips.isEmpty ? ([], first.problem ?? second.problem) : second
    }

    private static func query(_ host: String, _ extra: [String]) -> (ips: [String], problem: String?) {
        // 3 s, 2 tries: DNS through a phone hotspot can be slow for a name it has not seen yet.
        let r = Shell.run("/usr/bin/dig", ["-4"] + extra + ["+short", "+time=3", "+tries=2", "A", host])
        let lines = r.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let ips = r.ok ? lines.filter(Net.isIPv4).uniqued() : []
        if !ips.isEmpty { return (ips, nil) }
        let note = lines.first { $0.hasPrefix(";;") || $0.lowercased().contains("error") }?
            .trimmingCharacters(in: CharacterSet(charactersIn: "; ")).prefix(120)
        return ([], note.map(String.init) ?? (r.ok ? "no IPv4 address" : "dig failed"))
    }
}

/// Files in /etc/resolver that send only the VPN server names to our local answerer.
/// We only touch files that start with our marker.
enum ResolverFiles {
    static let dir = "/etc/resolver"

    static func sync(hosts: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let content = PinnedDNS.resolverFileContent
        var changed = false
        for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !hosts.contains(file) {
            let path = "\(dir)/\(file)"
            if let text = try? String(contentsOfFile: path, encoding: .utf8), text.hasPrefix(PinnedDNS.marker) {
                try? fm.removeItem(atPath: path)
                changed = true
            }
        }
        for host in hosts where Net.isHostName(host) {
            let path = "\(dir)/\(host)"
            if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
                if existing == content { continue }
                guard existing.hasPrefix(PinnedDNS.marker) else {
                    Log.error("\(path) exists and was not made by VPN Guard; leaving it alone")
                    continue
                }
            }
            do {
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
                changed = true
            } catch {
                Log.error("Cannot write \(path): \(error)")
            }
        }
        if changed {
            Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            Log.info("Local DNS answers for: \(hosts.isEmpty ? "(none)" : hosts.joined(separator: ", "))")
        }
    }
}

/// UDP DNS answerer on 127.0.0.1:PinnedDNS.port. Loopback only; pf always allows lo0.
final class PinnedDNSServer {
    private let queue = DispatchQueue(label: "local.vpnguard.dns")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var pins: [String: [String]] = [:]

    func start() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { Log.error("DNS answerer: socket() failed"); return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = PinnedDNS.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            Log.error("DNS answerer: cannot listen on 127.0.0.1:\(PinnedDNS.port) (errno \(errno))")
            close(fd)
            fd = -1
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.receive() }
        src.resume()
        source = src
    }

    func update(_ newPins: [String: [String]]) {
        queue.async { self.pins = newPins }
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 1500)
        var from = sockaddr_storage()
        var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
        }
        guard n > 0, let reply = PinnedDNS.reply(to: Array(buf[0..<n]), pins: pins) else { return }
        _ = withUnsafePointer(to: &from) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                reply.withUnsafeBytes { sendto(fd, $0.baseAddress, reply.count, 0, sa, fromLen) }
            }
        }
    }
}

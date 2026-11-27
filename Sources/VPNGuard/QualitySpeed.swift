import Foundation
import VPNGuardCore

/// Speed against a server's test files (Cloudflare, Vultr): several downloads at once for a few
/// seconds, then (Cloudflare) several uploads. Requests start again as they finish until the time is
/// up; the first second is not counted (TCP is still speeding up).
final class HTTPSpeedTest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum Phase { case idle, down(URL), up(URL) }

    private let lock = NSLock()
    private var bytesIn: Int64 = 0
    private var bytesOut: Int64 = 0
    private var phase: Phase = .idle
    /// Requests that failed in this phase: after a few, stop starting new ones (the server refuses).
    private var failures = 0
    private var session: URLSession!
    /// Small pieces, counted when the server confirms them (bytes handed to the system are not sent yet).
    private static let uploadBody = Data(count: 2_000_000)

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 10
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Download and, if `upload` is given, upload speed in Mbps, and the data used in MB.
    func run(download: URL, upload: URL?, seconds: Double) async -> (down: Double, up: Double, megabytes: Double) {
        let down = await measure(.down(download), seconds: seconds)
        let up = upload == nil ? (mbps: 0.0, bytes: Int64(0)) : await measure(.up(upload!), seconds: max(4, seconds * 0.75))
        session.invalidateAndCancel()
        return (down.mbps, up.mbps, Double(down.bytes + up.bytes) / 1_000_000)
    }

    func cancel() {
        lock.lock(); phase = .idle; lock.unlock()
        session.invalidateAndCancel()
    }

    private func measure(_ p: Phase, seconds: Double, streams: Int = 4) async -> (mbps: Double, bytes: Int64) {
        lock.withLock { phase = p; bytesIn = 0; bytesOut = 0; failures = 0 }
        for _ in 0..<streams { start() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let warm = counted()
        let started = Date()
        try? await Task.sleep(nanoseconds: UInt64(max(1, seconds - 1) * 1_000_000_000))
        let total = counted()
        let elapsed = Date().timeIntervalSince(started)
        lock.withLock { phase = .idle }
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
        guard elapsed > 0 else { return (0, total) }
        return (Double(total - warm) * 8 / elapsed / 1_000_000, total)
    }

    private func counted() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if case .up = phase { return bytesOut }
        return bytesIn
    }

    private func start() {
        lock.lock(); let p = phase; lock.unlock()
        switch p {
        case .idle:
            return
        case .down(let url):
            session.dataTask(with: URLRequest(url: url)).resume()
        case .up(let url):
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            session.uploadTask(with: r, from: Self.uploadBody).resume()
        }
    }

    /// Only a 2xx answer is a test file; an error page must not count as speed.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask is URLSessionUploadTask == false else { return }
        lock.lock(); bytesIn += Int64(data.count); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ok = error == nil && ((task.response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
        lock.lock()
        if ok, task is URLSessionUploadTask { bytesOut += Int64(Self.uploadBody.count) }
        if !ok { failures += 1 }
        let again = failures < 8
        lock.unlock()
        // Finished before the time was up: start another one (unless the server keeps refusing).
        if (error as? URLError)?.code != .cancelled, again { start() }
    }
}

/// Checks from a terminal: `VPNGuard --servers` pings every test server; `VPNGuard --speedtest
/// cloudflare:nearest 6` runs a speed test against a server's files for that many seconds.
enum QualityCLI {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--servers") {
            var times: [(TestServer, Double?)] = []
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: TestServers.all.count) { i in
                let s = TestServers.all[i]
                let ms = QualityMonitor.ping(s)
                lock.withLock { times.append((s, ms)) }
            }
            for (s, ms) in times.sorted(by: { ($0.1 ?? 9_999) < ($1.1 ?? 9_999) }) {
                print(String(format: "%7@  %@  (%@)", ms.map { String(format: "%.0f ms", $0) } ?? "–", s.title, s.abilities))
            }
            exit(0)
        }
        guard let i = args.firstIndex(of: "--speedtest"), i + 1 < args.count else { return }
        let s = TestServers.server(id: args[i + 1])
        let seconds = i + 2 < args.count ? Double(args[i + 2]) ?? 6 : 6
        guard let down = s.downloadURL.flatMap(URL.init(string:)) else { print("\(s.title) has no speed files"); exit(1) }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let r = await HTTPSpeedTest().run(download: down, upload: s.uploadURL.flatMap(URL.init(string:)), seconds: seconds)
            print(String(format: "%@: down %.1f Mbps, up %.1f Mbps, used %.0f MB", s.title, r.down, r.up, r.megabytes))
            done.signal()
        }
        done.wait()
        exit(0)
    }
}

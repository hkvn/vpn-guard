import Foundation

/// XPC interface of the helper. One method keeps the protocol stable; the payload is JSON.
@objc public protocol VPNGuardHelperProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum HelperError: LocalizedError, Sendable {
    case notReachable(String)
    case timeout
    case badReply
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .notReachable(let why): return "Cannot reach the VPN Guard helper (\(why))."
        case .timeout: return "The VPN Guard helper did not answer."
        case .badReply: return "The VPN Guard helper sent a reply I don't understand."
        case .remote(let message): return message
        }
    }
}

/// Calls a completion handler only once (reply, error or timeout, whichever comes first).
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((T) -> Void)?

    init(_ handler: @escaping (T) -> Void) { self.handler = handler }

    func call(_ value: T) {
        lock.lock()
        let h = handler
        handler = nil
        lock.unlock()
        h?(value)
    }
}

/// Client used by the menu bar app and the CLI.
public final class HelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: VG.machService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: VPNGuardHelperProtocol.self)
        c.invalidationHandler = { [weak self] in self?.dropConnection() }
        c.interruptionHandler = { [weak self] in self?.dropConnection() }
        c.resume()
        connection = c
        return c
    }

    private func dropConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }

    public func send(_ command: HelperCommand, timeout: TimeInterval = 8,
                     completion: @escaping @Sendable (Result<GuardStatus, Error>) -> Void) {
        let once = Once<Result<GuardStatus, Error>>(completion)
        let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
            once.call(.failure(HelperError.notReachable(error.localizedDescription)))
        } as? VPNGuardHelperProtocol
        guard let proxy else {
            once.call(.failure(HelperError.notReachable("no proxy")))
            return
        }
        proxy.perform(Wire.encode(command)) { data in
            guard let reply = try? Wire.decode(HelperReply.self, from: data) else {
                once.call(.failure(HelperError.badReply))
                return
            }
            if let message = reply.error {
                once.call(.failure(HelperError.remote(message)))
            } else if let status = reply.status {
                once.call(.success(status))
            } else {
                once.call(.failure(HelperError.badReply))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            once.call(.failure(HelperError.timeout))
        }
    }

    /// Blocking version for the CLI.
    public func sendSync(_ command: HelperCommand, timeout: TimeInterval = 8) -> Result<GuardStatus, Error> {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        send(command, timeout: timeout) { result in
            box.value = result
            sem.signal()
        }
        sem.wait()
        return box.value ?? .failure(HelperError.timeout)
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<GuardStatus, Error>?
}

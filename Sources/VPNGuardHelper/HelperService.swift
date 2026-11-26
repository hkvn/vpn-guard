import Foundation
import Security
import VPNGuardCore

/// XPC endpoint. Only our own code may call it: the same team and identifiers when signed with a
/// certificate, or the exact pinned code hashes when ad-hoc signed (see `ClientTrust`).
final class HelperService: NSObject, NSXPCListenerDelegate, VPNGuardHelperProtocol {
    private let engine: Engine
    private let requirement: String

    init(engine: Engine) {
        self.engine = engine
        self.requirement = CodeSigning.clientRequirement()
        super.init()
        Log.info("XPC clients must satisfy: \(requirement)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: VPNGuardHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func perform(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        engine.queue.async { [engine] in
            var answer = HelperReply()
            do {
                let command = try Wire.decode(HelperCommand.self, from: request)
                answer.status = try engine.handle(command)
            } catch {
                answer.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                answer.status = engine.status
            }
            reply(Wire.encode(answer))
        }
    }
}

enum CodeSigning {
    /// Team ID of the certificate this binary is signed with, or nil if ad-hoc signed.
    static func ownTeamID() -> String? {
        guard let info = ownSigningInfo() else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// cdhash of the running helper binary (the `vpnguard` CLI is the same binary).
    static func ownCDHash() -> String? {
        guard let info = ownSigningInfo() else { return nil }
        return hex(info[kSecCodeInfoUnique as String])
    }

    /// cdhashes of an app bundle, one per architecture it contains (arm64, x86_64), after checking
    /// that its signature is intact and that it is VPN Guard.
    static func appCDHashes(at url: URL) throws -> [String] {
        var hashes: [String] = []
        for arch in ["arm64", "x86_64"] {
            var code: SecStaticCode?
            let attrs = [kSecCodeAttributeArchitecture as String: arch] as CFDictionary
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, SecCSFlags(), attrs, &code) == errSecSuccess,
                  let code
            else { continue }
            let check = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
            guard check == errSecSuccess else {
                throw PinError("The app's signature is broken (\(arch), error \(check)). Download VPN Guard again.")
            }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let dict = info as? [String: Any]
            else { continue }
            guard dict[kSecCodeInfoIdentifier as String] as? String == VG.appBundleID else {
                throw PinError("\(url.path) is not VPN Guard.")
            }
            if let h = hex(dict[kSecCodeInfoUnique as String]) { hashes.append(h) }
        }
        guard !hashes.isEmpty else { throw PinError("No signed VPN Guard app found at \(url.path).") }
        return hashes.uniqued()
    }

    static func pinnedCDHashes() -> [String] {
        guard let data = FileManager.default.contents(atPath: VG.clientPinsPath),
              let pins = try? Wire.decode(ClientPins.self, from: data)
        else { return [] }
        return pins.validHashes
    }

    static func clientRequirement() -> String {
        let team = ownTeamID()
        return ClientTrust.requirement(
            teamID: team,
            ownCDHash: ownCDHash(),
            pinnedCDHashes: team == nil ? pinnedCDHashes() : []
        )
    }

    struct PinError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func ownSigningInfo() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    private static func hex(_ value: Any?) -> String? {
        guard let data = value as? Data, !data.isEmpty else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

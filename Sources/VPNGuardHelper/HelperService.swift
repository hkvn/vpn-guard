import Foundation
import Security
import VPNGuardCore

/// XPC endpoint. Only code signed like this helper (same team, our two identifiers) may call it.
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
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func clientRequirement() -> String {
        let ids = "(identifier \"\(VG.appBundleID)\" or identifier \"\(VG.helperLabel)\")"
        if let team = ownTeamID(), !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and \(ids)"
        }
        return ids
    }
}

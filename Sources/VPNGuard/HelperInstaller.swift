import Foundation

/// Installs the root helper with the standard macOS admin password dialog.
/// The scripts and the helper binary ship inside the app: Contents/Resources/helper/.
@MainActor
enum HelperInstaller {
    enum Failure: LocalizedError {
        case missingFiles
        case cancelled
        case script(String)

        var errorDescription: String? {
            switch self {
            case .missingFiles: return "The helper files are missing from the app bundle. Rebuild the app."
            case .cancelled: return "Cancelled."
            case .script(let message): return message
            }
        }
    }

    static func install() throws { try run("install-helper.sh") }
    static func uninstall() throws { try run("uninstall-helper.sh") }

    private static func run(_ script: String) throws {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("helper"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent(script).path)
        else { throw Failure.missingFiles }

        let command = "/bin/bash \(shellQuote(dir.appendingPathComponent(script).path)) \(shellQuote(dir.path))"
        let source = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            throw Failure.script((error[NSAppleScript.errorMessage] as? String) ?? "Unknown error")
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

import Foundation
import VPNGuardCore

// The same binary is the root daemon (`run`, started by launchd) and the `vpnguard` CLI.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "run" {
    guard getuid() == 0 else {
        FileHandle.standardError.write(Data("`run` is for launchd (root) only. Try `vpnguard status`.\n".utf8))
        exit(1)
    }
    signal(SIGPIPE, SIG_IGN)
    let engine = Engine()
    engine.start()
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    sigterm.setEventHandler {
        Log.info("Stopping")
        engine.shutdown()
        exit(0)
    }
    sigterm.resume()
    let service = HelperService(engine: engine)
    let listener = NSXPCListener(machServiceName: VG.machService)
    listener.delegate = service
    listener.resume()
    withExtendedLifetime((engine, service, listener, sigterm)) {
        dispatchMain()
    }
} else {
    exit(CLI.run(arguments))
}

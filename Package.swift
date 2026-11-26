// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VPNGuard",
    platforms: [.macOS(.v15)],
    targets: [
        // Shared code: models, rules, policy, XPC protocol and client.
        .target(name: "VPNGuardCore"),
        // Root helper (LaunchDaemon). Also works as the `vpnguard` CLI.
        .executableTarget(name: "VPNGuardHelper", dependencies: ["VPNGuardCore"]),
        // Menu bar app.
        .executableTarget(name: "VPNGuard", dependencies: ["VPNGuardCore"]),
        .testTarget(name: "VPNGuardCoreTests", dependencies: ["VPNGuardCore"]),
    ],
    swiftLanguageModes: [.v5]
)

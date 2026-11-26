# Changelog

All notable changes. Versions follow [Semantic Versioning](https://semver.org).

## 1.1.1 — 2026-11-26

### Added
- **Download and use:** a DMG for every release, one app for Apple silicon and Intel, built in public
  by GitHub Actions with a SHA-256 checksum. Nothing else to install.

### Security
- Builds without a certificate (like the DMG) no longer trust the app's name. The helper records the
  exact code hashes of the app copy that installed it and accepts only that copy and the `vpnguard`
  tool. After an app update, reinstall the helper once.
- The app, the helper and the WireGuard engine now use the hardened runtime (no code injection).
- The helper installer clears the download quarantine flag on the files it installs.

## 1.1.0 — 2026-11-26

### Added
- **Built-in WireGuard client.** The helper ships and runs `wireguard-go`; import a `.conf` file or
  create a new key pair (with a ready MikroTik peer command). Full and split tunnels, tunnel DNS,
  automatic restart, data counters. CLI: `vpnguard wg …`.
- **Create L2TP and IKEv2 VPNs in the app** as Apple configuration profiles with "Send all traffic"
  always on.
- **Settings redesign:** menu at the top, header cards, slim lists with ⓘ detail sheets and +/− bars,
  light and dark mode.
- **Animated status shield** in the popover; press and hold it to turn protection on or off.
- "Needs a fix" check for macOS VPNs with "Send all traffic" off, with a one-click copy that fixes it.

### Changed
- Only one VPN runs at a time: choosing another VPN disconnects the old one.
- VPNs from other apps (such as Tailscale) are shown as "Other app" and no longer get a false warning.

## 1.0.2 — 2026-11-26

### Changed
- VPN server host names are answered by a small DNS answerer in the helper (only those names, on
  `127.0.0.1`), selected through `/etc/resolver`. `/etc/hosts` is never touched.

## 1.0.1 — 2026-11-26

### Fixed
- The VPN could not connect while locked: the chosen VPN's server is now added to the allowed list
  automatically, and host-name servers are looked up while DNS works.

## 1.0.0 — 2026-11-26

### Added
- Root helper with a pf kill switch in its own anchor, event-driven network detection, trusted
  networks by router hardware address, fail-closed policy, safety re-checks.
- SwiftUI menu bar app with state icons, popover, Settings and welcome window; auto connect and
  disconnect of macOS VPNs; pause with countdown.
- `vpnguard` command line tool.

# Changelog

All notable changes. Versions follow [Semantic Versioning](https://semver.org).

## 1.2.2 — unreleased

From testing on a real Mac with office Wi‑Fi, a LAN cable and an iPhone over USB.

### Added
- **Settings → Networks shows details** of each network you are on: your address, router, router
  hardware address, DNS servers, trusted since, and whether internet goes out there. The one in use is
  first and framed.
- **Colored menu bar icon** (Settings → General → Menu bar icon): each state in its own color, so you
  can tell them apart at a glance. Monochrome, like other Mac icons, stays the default.

### Changed
- The network your Mac uses is shown **first and highlighted** (a frame in the state's color and
  "● In use"). Long card names are shorter ("USB 10/100/1000 LAN" is now "USB LAN").
- Network card icons show how you are connected (Wi‑Fi, cable, phone) instead of guessing from the name.

### Fixed
- **Protection off or Pause now disconnects the VPN that VPN Guard started by itself** (it stayed on).
  It starts again when protection comes back. A VPN you connected by hand stays on.
- Letting go of the status shield before the ring is full no longer keeps the ring filling.
- The popover window could stay taller than its content after a change (an empty band at the top and
  the bottom, broken corners), seen in the "Protection is off" state.

## 1.2.1 — 2026-11-26

Found in a real test with an iPhone over USB.

### Fixed
- **VPN failed to connect at first on IPv6 phone hotspots (NAT64).** On many mobile networks macOS reaches
  the VPN server by an IPv6 address made from its IPv4 one (`64:ff9b::…`). The lock allowed only IPv4,
  so the first tries failed until macOS used IPv4. Now the VPN servers' NAT64 addresses are allowed,
  plus IPv6 neighbor discovery on the local network. All other IPv6 stays blocked.
- Looking up VPN server names waits longer (3 s, 2 tries): DNS through a phone can be slow.

## 1.2.0 — 2026-11-26

### Changed
- **Two networks at once** (office Wi‑Fi + iPhone over USB): each card is judged on its own. The trusted
  one works as normal, the untrusted one may only be used by the VPN ("VPN only"). Before, the whole Mac
  locked, and at the office the VPN usually cannot connect, so there was no internet. If macOS sends
  traffic through the untrusted card, the VPN starts and everything goes through it.

### Added
- **"Trust which network?"**: with several networks, or on a phone hotspot, you tick what to trust.
  Only the network your Mac uses is ticked; a phone hotspot is never ticked for you and shows a warning.
- The popover shows which network is **in use** when there are several.

## 1.1.3 — 2026-11-26

Fixes from a second review, of network loss and network change.

### Fixed
- **A pause followed you to the next network**: pause at a hotel, walk to a café within the time, and
  you were unprotected there. A pause now ends as soon as you join another network.
- WireGuard sent its connection through the first network card by name (Wi‑Fi) even when macOS used
  another one (cable): now it uses the network macOS really uses.
- A short Wi‑Fi drop or sleep counted as a new network: a VPN you connected by hand at the office was
  disconnected again, and one you disconnected at a café came back. Your choice is now kept on the
  same network.
- Server names are looked up when you join a new network, also when the Mac was already locked.
- With two networks up, an L2TP VPN is restarted when exactly the one it uses goes away.
- While there is no network or the router is still being checked, blocked traffic is dropped quietly,
  so open connections (SSH, calls) survive a short Wi‑Fi drop on a trusted network.

### Added
- `vpnguard detect` shows which network the internet goes out through.

## 1.1.2 — 2026-11-26

Fixes from a logic review after a real "the VPN does not reconnect" report.

### Fixed
- **Switching VPN while blocked could make the VPN unable to connect** until protection was turned
  off: the saved IP of a host-name server was deleted, and DNS was blocked. Now the servers of all
  your VPNs stay allowed, and saved IPs are kept.
- **VPN server names can be looked up while blocked**, so a new VPN or a home server whose IP changed
  (dynamic DNS) connects without turning protection off. The firewall lets the helper's own DNS
  lookup out from one port for about a second, then closes it again.
- Server names are looked up at once when the lock turns on or off (it took up to a minute), and a
  lookup asked for during another one is no longer dropped.
- If the router's hardware address stays unknown (some USB or 4G modems), the VPN now starts after
  5 seconds instead of never.
- Choosing another VPN quickly now always stops the one that was still connecting.
- Trusting a network seen over Wi-Fi and a cable at the same time makes one entry, not two.
- An L2TP VPN is restarted at once when you move to another network, instead of after up to 80 s.

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

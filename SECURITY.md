# Security

VPN Guard is a security tool, so please read what it does and does not protect.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on this repository. Include the macOS version, the VPN Guard
version (`vpnguard status`), steps to reproduce, and what you expected.

You should get an answer within a week. Fixes go into the next release and are credited in the
changelog unless you ask otherwise.

## Supported versions

Only the latest release gets security fixes.

## What VPN Guard protects against

The goal: **on a network you do not trust, no traffic leaves the Mac outside the VPN.**

- **Before the VPN connects, while it reconnects, and when it drops.** The firewall blocks everything
  except the VPN server, so apps cannot fall back to the direct connection.
- **IPv6 leaks.** IPv6 is blocked on real interfaces while locked (many VPNs, including L2TP in macOS,
  only carry IPv4).
- **DNS leaks.** DNS to the local network's resolver is blocked while locked. With WireGuard, the
  tunnel's DNS servers are used.
- **Connections made before the lock** (for example during a pause) are cut when the lock starts.
- **A fake network with your Wi‑Fi name.** Trust is tied to the router's hardware address, not the
  network name.
- **The app crashing or being quit.** The firewall rules are enforced by the root helper and stay in
  place; the helper is restarted by launchd if it stops.

## What it does not protect against

- **Trusted networks** are not filtered at all, by design.
- **While paused or with protection off**, traffic is not protected.
- **Software with root (admin) rights** can remove the rules or stop the helper. VPN Guard checks and
  repairs its rules every 30 seconds, but it cannot defend against an attacker who already has root.
- **Someone on an untrusted network who copies your trusted router's hardware address** (and gives the
  same router address) could make VPN Guard open the network. They would need to know that address.
- **Your VPN itself.** VPN Guard makes sure traffic goes into the VPN; what happens after the VPN server
  is up to the VPN.
- **A short window when joining a network.** The lock follows the network state that macOS publishes,
  which happens within milliseconds, before apps normally start new connections.
- **Traffic of other VPN apps' own tunnels** is allowed into their tunnel interface, but their outer
  traffic still leaves through a real interface and is filtered there, so it only works through your
  VPN.

## Design choices that matter for security

- **Fail closed.** No network, an unknown router, or one untrusted network among several: locked.
- **Least privilege.** Only the helper runs as root. The app and CLI run as the user and talk to the
  helper over XPC.
- **Who may control the helper.** Each XPC connection must be signed by the same Apple team as the
  helper, with the app's or the helper's identifier. **Ad-hoc builds** (no certificate) can only check
  the identifiers, which another local program could copy. If that matters to you, build with an
  Apple Development or Developer ID certificate (`scripts/build.sh` picks one automatically).
- **Input checks.** Everything that reaches `pfctl`, `ifconfig`, `route` or `/etc/resolver` is
  validated (IPv4 and CIDR syntax, interface names, host names). Unit tests try injection strings.
- **Secrets.** WireGuard private keys are stored root-only (0600), written so they are never readable
  by others even for a moment, and never sent back to the app. L2TP/IKEv2 passwords go only into
  macOS's keychain through a configuration profile; the temporary profile file is readable only by
  you and deleted after 10 minutes.
- **No telemetry.** VPN Guard sends nothing anywhere. The only network traffic it makes itself is a
  ping to the local router (to read its hardware address) and DNS lookups of your VPN server names.

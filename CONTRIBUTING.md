# Contributing

Thanks for helping! Bug reports, fixes, translations and design ideas are all welcome.

## Getting started

You need macOS 15+, Xcode 16+ (Swift 6) and Go 1.22+ (only to build the bundled WireGuard engine).

```bash
swift build                 # debug build of everything
swift test                  # unit tests (Core: policy, pf rules, input checks, WireGuard, DNS, profiles)
scripts/build.sh            # release app bundle in build/VPN Guard.app (signed if a certificate is found)
scripts/install.sh          # build, copy to /Applications, update the helper if installed
```

`SIGN_IDENTITY=- scripts/build.sh` forces ad-hoc signing. `SKIP_HELPER=1 scripts/install.sh` installs
only the app (no password prompt).

## Checking the UI without a helper

```bash
swift build && .build/debug/VPNGuard --render-previews /tmp/vpnguard-previews
```

This draws every screen (popover states, Settings pages, sheets, welcome) in light and dark mode with
made-up data. Please attach before/after images to UI pull requests.

## Project layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#source-layout). In short: pure logic goes in
`VPNGuardCore` (and gets tests), root-only work in `VPNGuardHelper`, UI in `VPNGuard`.

## How we work

- **Design first.** For a new screen or a visible change, share a design (sketch, mockup or preview
  images) in the issue before writing the code.
- **Security first.** Anything that reaches the firewall, the shell, routes or DNS files must be
  validated in Core and covered by a test. Fail closed when unsure.
- **Plain words in the UI.** Short sentences, no jargon where a simple word works. Say what happens
  ("The internet stops until the VPN connects"), not how.
- **Never ship personal data.** Use example values in tests and previews: `example.com`, and the
  documentation address ranges `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`.
- **Small pull requests** with a clear description and the commands you ran to test.

## Testing changes to the helper or firewall

Changing lock behavior can cut your own internet. Before testing lock mode, start a safety switch in
another terminal:

```bash
sleep 120 && vpnguard disable
```

Prefer split-tunnel WireGuard configs and test addresses (`192.0.2.x`) when testing tunnels.

## Releases

1. Update `VG.version` in `Sources/VPNGuardCore/Constants.swift` (the app offers a helper update when
   the versions differ).
2. Add the changes to `CHANGELOG.md`.
3. Tag `vX.Y.Z`.

By contributing you agree that your contribution is licensed under the GPL v3, like the rest of the
project.

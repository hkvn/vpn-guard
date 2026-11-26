# Troubleshooting

Start with `vpnguard status` and the log (`tail -50 /var/log/vpnguard.log`). They tell you what VPN
Guard sees and why it is open or locked.

## I have no internet at all

1. **Is it locked on purpose?** If the menu bar shows the shield with an X, the network is not trusted
   and the VPN is off. Connect the VPN, trust the network, or pause.
2. **Hotel or café Wi‑Fi with a login page?** Use **Pause**, sign in, then resume.
3. **Emergency off switch** (works even if the app or helper is broken):

   ```bash
   sudo pfctl -a com.apple/000.vpnguard -F all
   ```

   The helper locks again on the next network change if protection is on. To stop that too:
   `vpnguard disable`, or uninstall the helper. Restarting the Mac also clears the rules until the
   helper starts.

## The VPN connects, but websites do not open

- **"Send all traffic" is off** for that macOS VPN. VPN Guard marks it *Needs a fix*. Turn it on in
  System Settings → VPN → ⓘ → Options, or use *Make a New Copy…* in its ⓘ sheet.
- **WireGuard:** the router does not forward or NAT traffic from the VPN network. See
  [the MikroTik section](USER_GUIDE.md#5-wireguard-on-a-mikrotik-router).
- **WireGuard without DNS:** add `DNS = 1.1.1.1` to the `.conf` file (or the DNS field), then add the
  VPN again.

## The VPN does not connect while blocked

- Check **Settings → VPN → Allowed servers…**. The VPN's server must be there with an IP. A host name
  that shows *IP not known yet* could not be looked up: check the log for "Could not look up VPN
  server". If the network's DNS does not answer, pause for a minute, then resume.
- You are **at the office or at home and the network is not trusted yet**: a VPN to your own office
  usually cannot connect from inside it. Trust the network.
- L2TP: connect it once from System Settings so macOS saves the password.

## WireGuard says "Waiting for the server to answer"

The tunnel is up but no handshake came back.

- Wrong server public key, or this Mac's public key is not added on the server (Settings → VPN → ⓘ →
  *Copy My Public Key* / *Copy MikroTik Command*).
- The server's UDP port is not open in its firewall.
- The endpoint host name points to an old IP (see the previous section).

`vpnguard wg list` shows the interface, bytes sent and received, and the last error.

## macOS says "VPN Guard" was not opened

The free DMG is not notarized by Apple, so macOS blocks the first start. Click **Done**, open
**System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to VPN Guard.
To check the download first: `shasum -a 256 VPN-Guard-x.y.z.dmg` must match the `.sha256` file on the
release page.

## "Needs attention" right after updating the app

Expected once per update. The helper only accepts the exact app copy that installed it, and a new
copy is a different app to it. Click **Reinstall Helper…** and type your password. Protection stays on
meanwhile.

## The app says "Helper not responding" or "Needs attention"

Reinstall the helper: Settings → Helper & About → **Reinstall…** (or the button in the popover). If it
keeps failing, check the log and `sudo launchctl print system/local.vpnguard.helper`.

## A trusted network is not recognized

The router was replaced or the Mac reaches the network through a different router. Run
`vpnguard detect`, compare the router hardware address with Settings → Networks → ⓘ, and trust the
network again.

## AirDrop, AirPlay, printers or Tailscale stop working

That is expected while locked: only the VPN may use the network. They work on trusted networks, while
paused, or (for Tailscale) when its traffic goes through your VPN.

## Collecting information for a bug report

```bash
vpnguard status
vpnguard detect
vpnguard rules
tail -100 /var/log/vpnguard.log
sw_vers
```

Remove anything private (public IPs, router hardware addresses, host names) before you post it.

# vpn-guard

Pause the transfer client and load a PF kill anchor whenever the macOS network
is unsafe:

- ExpressVPN is not connected, OR
- The current Wi-Fi SSID looks like a phone hotspot.

Detection uses deterministic ground truth instead of fragile signals:

- VPN: `expressvpnctl status` from the modern ExpressVPN macOS app bundle.
- Hotspot: SSID substring list, known tether subnets, and a conservative
  locally-administered gateway-MAC signal. A known non-hotspot router that uses
  such a MAC can be exempted by exact address in
  `~/.config/vpn-guard/trusted-gateway-macs.txt`; explicit SSID and subnet
  matches still win.

Defense in depth:

1. App-level: pause all transfers via the client's local Web UI API, with a
   `pkill -STOP` fallback if the API is unreachable.
2. Network-level: PF anchor `vpn-guard` blocks the configured listen port
   `56378` and the legacy peer-transfer range on every interface, IPv4 + IPv6.

In the current layout, Server Monitor's single signed infrastructure agent runs
the guard as a non-overlapping 30-second job. The standalone LaunchAgent remains
only as the explicit `darkmesh setup --legacy-agents` fallback.

## Files

| File | Installs to | Purpose |
|------|-------------|---------|
| `vpn-guard.sh` | Homebrew/darkmesh tool directory | The guard logic |
| `unsafe.pf.conf` | `/usr/local/etc/vpn-guard/unsafe.pf.conf` | PF rules loaded into anchor `vpn-guard` |
| `com.user.vpnguard.plist` | `~/Library/LaunchAgents/` | Legacy scheduler template |
| `sudoers.d-vpn-guard` | `/etc/sudoers.d/vpn-guard` | NOPASSWD for fixed PF status, enable, arm, and flush commands |
| `hotspot-ssids.txt.example` | `~/.config/vpn-guard/hotspot-ssids.txt` | Editable SSID substring list |
| `trusted-gateway-macs.txt.example` | `~/.config/vpn-guard/trusted-gateway-macs.txt` | Exact allowlist for stable non-hotspot gateways with ambiguous MACs |
| `vpn-guard-install.sh` | - | One-shot installer |
| `vpn-guard-uninstall.sh` | - | Removal (`--purge` also wipes keychain + config) |

## Install

Install Server Monitor and the darkmesh formula, then run `darkmesh setup`. Use
`darkmesh setup --legacy-agents` only on a machine that cannot install the signed
app. `vpn-guard-install.sh` remains the separate credentialed setup path when the
transfer client's Web UI password is required.

Setup prompts for the transfer-client Web UI password and stores it in macOS
Keychain using service `vpn-guard-client`. The script reads it on each run via
`security find-generic-password`.

### Re-running Setup

`vpn-guard-install.sh` is idempotent and Keychain-aware:

| State at re-run | Behavior |
|---|---|
| No Keychain entry | Prompts for password, validates, stores. |
| Keychain entry validates against live client | Skips the prompt. |
| Keychain entry is rejected by the client | Re-prompts, validates, overwrites Keychain. |
| Wrong password typed at the prompt | Aborts without storing. |

### Managing The Stored Password

```bash
# Print the currently stored password
security find-generic-password -s vpn-guard-client -w

# Force vpn-guard-install.sh to re-prompt next run
security delete-generic-password -s vpn-guard-client

# Update in place
security add-generic-password -a "$USER" -s vpn-guard-client -w NEWPASSWORD -U
```

## Verify

```bash
# Force a check
/usr/local/bin/vpn-guard.sh

# Inspect current PF anchor
sudo pfctl -a com.apple/vpn-guard -s rules

# Logs
tail -f ~/Library/Logs/vpn-guard/vpn-guard.log
```

Expected behavior: when ExpressVPN is connected and SSID is not a hotspot, the
anchor should be empty. The transfer client runs only when its explicit intent
is `active`; a manual `paused` intent is never overridden by the guard.
Disconnect VPN and, within about 30 seconds or on the next network event, the
client pauses and the anchor populates with block rules.

## Caveats

- GitHub "private" gists are unlisted, not actually private. The client password
  lives only in your Keychain and never in the gist.
- Block rules use hardcoded ports matching the current client config. Change the
  client port, then update `unsafe.pf.conf`.
- IPv6 is covered explicitly. ExpressVPN's modern macOS app blocks IPv6 by
  default while connected, but the PF layer remains useful defense in depth.
- If you switch clients, the Web UI API call may not match, but the PF rules and
  `SIGSTOP` fallback still cut traffic for the configured process.
- `sudoers.d-vpn-guard` whitelists only fixed `pfctl` argv variants. Anything
  else still requires interactive sudo.

## Tunables

In `vpn-guard.sh`:

- `CLIENT_WEB_HOST` (default `http://127.0.0.1:8080`)
- `CLIENT_WEB_USER` (default `admin`)
- `KEYCHAIN_SERVICE` (default `vpn-guard-client`)
- `HOTSPOT_PATTERNS_FILE` (default `~/.config/vpn-guard/hotspot-ssids.txt`)
- `TRUSTED_GATEWAY_MACS_FILE` (default `~/.config/vpn-guard/trusted-gateway-macs.txt`)
- `DARKMESH_GUARD_REASSERT_SECONDS` (default `600`; unchanged states remain
  quiet between bounded safety reassertions)

In `unsafe.pf.conf`:

- Listen port `56378`
- Legacy peer-transfer range `6881-6889`

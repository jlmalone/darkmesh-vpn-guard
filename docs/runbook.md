# Darkmesh / vpn-guard runbook

Created: 2026-05-05

## Purpose

This documents the working design for using Tailscale and ExpressVPN together
on this Mac while keeping the transfer client fail-closed.

The goal is not "make all networking convenient." The goal is:

1. Tailscale remains usable while ExpressVPN is connected.
2. The transfer client never gets a non-ExpressVPN path.
3. When the client breaks because the ExpressVPN tunnel changed, the failure is
   understandable and repairable.

## Component boundaries

### darkmesh

`darkmesh` should own Tailscale / ExpressVPN coexistence.

The old darkmesh route/DNS script is superseded for this use case because it
required the commercial VPN kill switch to be disabled. That violates the
transfer-client requirement.

The new darkmesh job is:

- Keep ExpressVPN Network Lock **off** (relaxed) — fail-closed for the transfer
  client comes from its tunnel socket-binding + PF, not the kill switch (which can
  trap general internet). Connectivity is paramount.
- Enable ExpressVPN split tunneling.
- Bypass only Tailscale's app and network extension.
- Keep MagicDNS working.
- Never add the transfer client to ExpressVPN bypass rules.

### vpn-guard

`vpn-guard` should own enforcement and local safety checks.

Current responsibilities:

- Detect ExpressVPN connected/disconnected state.
- Detect unsafe SSIDs / hotspots.
- Pause or stop the transfer client when unsafe.
- Load PF kill rules when unsafe (nested under `com.apple/vpn-guard` so the main
  ruleset's `com.apple/*` wildcard evaluates them); flush them when safe.
- Ensure PF is enabled, and publish PF state to the status file.
- Provide transfer-client VPN binding diagnostics.

Current helper:

- `transfer-vpn-doctor` resolved through `PATH` (Homebrew installs it under its
  active prefix; do not pin monitoring config to a retired install location).

### server_monitor

`server_monitor` should not own the network manipulation.

It should be a display and control surface only:

- Read `vpn-guard` state.
- Display GO / NO-GO.
- Explain stale transfer-client binding.
- Offer commands that call documented helpers.

This keeps the Swift menu-bar app from becoming the source of truth for network
policy.

## Current working state

ExpressVPN:

- Connected to a nearby region (best-effort).
- Network Lock: off (relaxed).
- Split Tunnel: enabled.
- Autoconnect: enabled (startup only; the captive-aware reconnect watchdog is the
  on-network connector).
- Split Tunnel bypass list:
  - `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
  - `/Library/SystemExtensions/.../io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension`

Tailscale:

- Use the bundled app CLI:
  - `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
- Do not rely on the Homebrew `tailscale` service for this Mac.
- The broken Homebrew user LaunchAgent was stopped:
  - `brew services stop tailscale`

Transfer client:

- The client is not in ExpressVPN split-tunnel bypass rules.
- The client is bound to the current ExpressVPN tunnel, not Wi-Fi.
- The client starts paused.
- UPnP/NAT-PMP is disabled.

Representative setup:

- Tailscale interface: `<tailscale-utun>`
- Tailscale IP: `<tailnet-address>`
- ExpressVPN interface: `<vpn-utun>`
- ExpressVPN tunnel-side IP: `<vpn-address>`

The concrete client config path and section name are derived by
`transfer-vpn-doctor` at runtime from weakly encoded identifiers.

## Why The Client May Get "Stuck"

The transfer-client binding is intentionally fail-closed.

If ExpressVPN reconnects later as a different `utun` interface or with a
different tunnel-side IP, the client will not silently fall back to Wi-Fi or
Tailscale. It may simply fail to transfer.

That is the desired security behavior, but it needs a clear explanation path.

Use:

```bash
transfer-vpn-doctor
```

Expected healthy output includes:

```text
ExpressVPN:
  connectionstate: Connected
  networklock:     true
  splittunnel:     true
  tunnel:          <vpn-utun> <vpn-address>

Tailscale:
  interface:       utun2

Transfer client config:
  InterfaceName:   <vpn-utun>
  InterfaceAddress:<vpn-address>
  StartPaused:     true
  UPnP:            false

OK: client binding matches the current ExpressVPN tunnel.
```

If it says `STALE-BINDING`, the client is stuck because its saved binding no
longer matches ExpressVPN's current tunnel. That is a safe failure, not a leak.

To repair while the client is closed:

```bash
transfer-vpn-doctor --fix
```

To let the helper quit the client first:

```bash
transfer-vpn-doctor --fix --quit
```

The helper refuses to fix when:

- ExpressVPN is not connected.
- The ExpressVPN tunnel cannot be identified.
- The detected ExpressVPN interface equals the Tailscale interface.
- The client is running and `--quit` was not provided.

## Travel / captive networks

darkmesh is built so a captive portal (hotel, cafe, airport, bank) NEVER blocks you
from getting online — connectivity is paramount:

- The reconnect watchdog requires positive captive evidence, such as a redirect
  or portal body, before declaring a portal. It restores plain networking once
  on entry and does not attempt the VPN while that evidence remains.
- Failure to reach Apple or Google without portal evidence is classified as a
  restricted network. Darkmesh permits two rate-limited VPN attempts because the
  VPN may be required to make the internet usable in filtered regions.
- The healthcheck stands down too. When the reconnect watchdog reports its
  `captive-standdown` phase, the healthcheck returns `verdict=CAPTIVE` (the first
  branch it evaluates) and performs zero DNS recovery, so it cannot repin DNS to a
  tunnel-range resolver while you are signing in. Both guards must stand down; one
  alone is not enough (see the 2026-06-23 entry in `docs/investigation-log.md`).
- After a hardening change, confirm the new code is actually installed on each
  machine, not just merged. A captive failure on 2026-06-23 was pure install
  drift: the fix was in the tree but the laptop still ran the prior healthcheck.
- Immediate, no-sudo "just get me online": `darkmesh-captive` (sets `vpn-desired=off`,
  Network Lock off, disconnects ExpressVPN). Sign in, then `darkmesh-up` to re-arm.
- Heavier reset (removes routes/resolvers, sudo once): `darkmesh-panic`.
- The transfer client stays fail-closed throughout (only ever runs over the VPN), so
nothing leaks while you're on open wifi.

The exact states, retry limits, and signal rules are documented in
`docs/network-resilience-state-machine.md`.

## Foreign VPN resolver recovery

A second VPN client can leave a dead resolver in `100.64.0.0/10` ahead of the
active network's DHCP DNS. Turning Tailscale MagicDNS off does not fix that
state: macOS simply falls through to the other dead resolver.

The schema-4 healthcheck handles this without assuming which product owns the
resolver:

1. It proves system DNS is dead across consecutive ticks.
2. It disables MagicDNS and inventories system + DHCP resolvers.
3. It directly proves the current DHCP resolver answers.
4. The scoped root helper snapshots the active service's exact prior DNS config
   and temporarily promotes those DHCP servers.
5. It restores the snapshot when the interface, gateway, or DHCP DNS changes,
   or after the poison disappears.

Install the permanent privilege once per machine:

```bash
sudo scripts/install-root-helper.sh "$(id -un)"
```

Authorized verbs are only `dns-flush`, `dns-override`, `dns-restore`, and (when
its launchd target was found during install) `restart-crd`. Recovery is bounded
by a persistent per-fault circuit breaker. One-shot healthchecks are read-only;
only the locked launchd watcher can mutate breaker or recovery state.

## Full Disk Access (external volumes) — manual, per machine

Separate from networking: if the transfer client serves data from an **external /
removable volume**, macOS requires it to have **Full Disk Access** (TCC). Without it
the client can read internal-disk files but silently cannot open files on the external
volume (it looks stuck at 0%). Do **not** hand-edit `TCC.db` — a bad edit wipes the
grants other tools rely on.

Fix on the machine's screen (physically or via Chrome Remote Desktop):
System Settings → Privacy & Security → **Full Disk Access** → **+** → add the
transfer-client app → toggle on → restart the client.

## Verification Commands

ExpressVPN:

```bash
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl status
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl get networklock
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl get splittunnel
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl get split-app
```

Tailscale:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale netcheck
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
/Applications/Tailscale.app/Contents/MacOS/Tailscale ping node-2
```

Local interfaces:

```bash
ifconfig utun2
ifconfig utun3
netstat -rn -f inet
```

Transfer-client binding:

```bash
transfer-vpn-doctor
```

vpn-guard:

```bash
/usr/local/bin/vpn-guard.sh
tail -n 20 ~/Library/Logs/vpn-guard/vpn-guard.log
```

## Project Recommendation

This should live as its own small project, not inside `server_monitor`.

Recommended shape:

```text
darkmesh-vpn-guard/
  README.md
  docs/
    threat-model.md
    macos-expressvpn-tailscale.md
    transfer-client-fail-closed.md
    server-monitor-integration.md
  scripts/
    darkmesh-expressvpn-tailscale
    transfer-vpn-doctor
  vpn-guard/
    vpn-guard.sh
    unsafe.pf.conf
    vpn-guard-install.sh
  schemas/
    vpn-guard-state.schema.json
```

Then:

- darkmesh gist points to the Tailscale / ExpressVPN coexistence docs.
- vpn-guard gist points to enforcement and transfer-client safety docs.
- server_monitor consumes a state file from this project.

## What Should Go In A New Gist

Create a new gist or repo README with:

- The threat model.
- The final ExpressVPN split-tunnel setup.
- Why `en0` is wrong for the transfer client.
- The transfer-client fail-closed binding.
- The `transfer-vpn-doctor` workflow.
- How `vpn-guard` and `server_monitor` fit in.

This is important because the original "fix Tailscale" plan looked plausible
but would have weakened the transfer-client invariant if followed literally.

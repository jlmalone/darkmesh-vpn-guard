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
- Autoconnect: off; Darkmesh owns connection ordering through its captive-aware
  reconnect watchdog.
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

## ExpressVPN system-extension approval

Darkmesh and `expressvpnctl` can prepare split-tunnel bypasses and request the
ExpressVPN system extension, but they cannot approve it on an unmanaged Mac.
Treat this state as a human gate:

```text
com.expressvpn.vpn.splittunnel ... [activated waiting for user]
```

Leave ExpressVPN disconnected. At the machine's physical console, open:

System Settings > General > Login Items & Extensions > Network Extensions

Enable ExpressVPN and confirm `systemextensionsctl list` changes to `activated
enabled` before any reconnect test. Repeated CLI or GUI toggles do not bypass
approval and may simply revert Split Tunnel to off.

Chrome Remote Desktop may display the approval sheet with blank or redacted
rows. Do not attempt blind clicks, protected-database edits, reduced-security
boot settings, or device-management enrollment as workarounds. A managed fleet
may use a user-approved device-management policy; an unmanaged installation
requires local approval.

The concrete client config path and section name are derived by
`transfer-vpn-doctor` at runtime from weakly encoded identifiers.

## Staged coexistence experiments

The current experiment is an adaptive campaign, not a one-off protocol trial.
The normal entry point is one guided command:

```bash
darkmesh experiment start
```

It creates the private mode-`0600` target map interactively when needed, prints
the plan, pauses transfers, runs preflight, requires the operator to type an
exact live-change confirmation, executes the campaign, and prints the report.
Use `darkmesh experiment start --reconfigure` to replace existing target
values. The file is literal `KEY=value` data, is never sourced as shell, and
must remain untracked. The peers are passive targets. The experiment changes
network state only on the Mac where it runs.

The individual commands remain available for diagnostics and automation:

```bash
darkmesh experiment plan --profile staged
darkmesh-transfer pause
darkmesh experiment preflight
```

Preflight is read-only. It requires the ExpressVPN GUI and daemon to be running,
the split extension to be approved, ExpressVPN disconnected with VPN intent
off, transfer intent explicitly paused, the saved Lightway protocol and Seattle
selection present, PF containment enforced, both existing Tailscale/SSH
identities reachable, and ordinary internet and DNS healthy. A privilege error,
missing PF rule, unsupported split toggle, or pending extension approval is a
`PRECONDITION`, never evidence against a protocol.

PF containment accepts either a directly readable blocking anchor or the fresh
guard sidecar produced after a successful anchor load. In both paths, PF itself
must independently report enabled.

Run the live campaign only with explicit authority for local network changes:

```bash
darkmesh experiment run --profile staged
darkmesh experiment report
```

The campaign screens WireGuard, Lightway TCP, and Lightway UDP. OpenVPN is
excluded. It adaptively challenges connected protocols across Tailscale DNS,
Seattle and Smart selection, split-rule isolation, startup order, repeatability,
the real Darkmesh reconnect state machine, and an ordinary disconnect. A nearby
region is added only for ambiguous Lightway UDP negotiation. Passing screen
cases run twice more; a connection timeout receives one retry after complete
recovery.

Every mutation begins by pausing the transfer client and proving that PF
containment is active. The campaign never starts a transfer and never changes
ExpressVPN background mode. Tailscale `up` is rejected if it requests login,
authorization, or an identity replacement. The exact preflight transfer intent
is restored, which means a campaign that starts paused finishes paused. Resuming
transfers is a separate operator action after reviewing the report.

Convergence uses route, interface, resolver, VPN, and system-extension
fingerprints:

- baseline: three healthy samples and 15 seconds of fingerprint quiet, within
  180 seconds;
- connection: `Connected` within 150 seconds;
- VPN stabilization: at least 45 seconds, then three stable samples ten seconds
  apart, within 240 seconds;
- Tailscale: two successful Tailscale, TCP 22, and SSH samples for each peer,
  within 180 seconds;
- post-disconnect: three healthy samples and 20 seconds of fingerprint quiet,
  within 180 seconds.

Any fingerprint change resets the relevant stability counter. Independent case
and campaign deadmen request the same recovery. A failed case recovery stops
the campaign. Exact split-rule restoration also waits for bounded ExpressVPN
read-back convergence instead of treating asynchronous preference propagation
as an immediate restoration failure.

Evidence is stored under
`~/.local/share/darkmesh/experiments/<timestamp>-<pid>/` with mode `0700`.
It contains a read-only initial snapshot, timestamped JSONL observations,
read-only per-case JSON, a comparison report, and a read-only final-restoration
snapshot. Final verification requires ExpressVPN disconnected, intent off, the
exact protocol, region, complete split rules, Network Lock, autoconnect,
Tailscale preferences and identity restored, plus healthy internet, DNS,
Tailscale, TCP 22, and SSH to both peers.

`--capture-path-metadata` requests one administrator session before the
campaign. It records bounded textual route, process, and packet-header metadata.
It does not save raw packets, payloads, or a packet-capture file.

`darkmesh coexistence-trial` remains a no-argument compatibility wrapper for
the staged campaign. The autonomous `darkmesh-protocol-trial` is retired because
it lacked these restoration and convergence guarantees.

### Captive-network field profile

Use the separate field profile only while actually attached to a captive Wi-Fi
network:

```bash
darkmesh experiment plan --profile captive
darkmesh experiment run --profile captive
```

It requires positive portal evidence, forces transfer containment, verifies
DHCP DNS evidence, and invokes the normal captive standdown. It then stops for
owner sign-in and prints a mode-`0700` run directory. After signing in, resume
that exact snapshot:

```bash
darkmesh experiment run --profile captive --resume \
  ~/.local/share/darkmesh/experiments/<run>
```

Resume verifies internet, DNS, both passive peers, and controlled VPN rearm,
then performs the normal exact-state restoration. The profile never poisons
routes or DNS to simulate a portal on a home network. Any later campaign that
changes a peer machine remains separately owner-gated.

### Corrected historical conclusions

- ExpressVPN, Tailscale, SSH, and fail-closed transfer protection previously
  coexisted.
- WireGuard with `tailscale set --accept-dns=false` is the strongest historical
  success.
- Lightway stability is not historically established.
- Changing VPN region did not solve the historical DNS collision.
- ExpressVPN split tunneling affects the local network even while disconnected.
- The latest Seattle attempt stopped at ExpressVPN 14.2's root-only background
  mode precondition. It was not a fast Lightway failure.
- `provider rejected new flow` remains ambiguous without path evidence. Do not
  classify it as a provider block from the log string alone.

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

VPN and tailnet resolvers in `100.64.0.0/10` or
`fd7a:115c:a1e0::/48` are runtime-owned, not durable network-service
configuration. The privileged helper never journals them as restorable static
DNS. If an older journal contains one, `dns-restore` retires the service to
DHCP instead of putting the dead resolver back. This prevents a recovery loop
where internet returns temporarily and fails again when the journal ages out.

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

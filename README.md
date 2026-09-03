# darkmesh-vpn-guard

Tailscale + ExpressVPN coexistence with a fail-closed transfer client on macOS.

This project documents and packages the working setup for one strict invariant:

> The transfer client must never have a non-ExpressVPN network path.

Tailscale is allowed to bypass ExpressVPN so the tailnet stays usable. The
transfer client is never allowed to bypass ExpressVPN.

## Current Design

ExpressVPN owns the public internet tunnel.

Split-tunnel bypass list (everything else goes through ExpressVPN):

- `/Applications/Tailscale.app/Contents/MacOS/Tailscale` — so the tailnet stays usable
- `io.tailscale.ipn.macsys.network-extension` (every version on disk) — actual Tailscale network traffic
- Chrome Remote Desktop host binaries under `/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/`
  (`remoting_me2me_host`, `remoting_me2me_host_service`, `remoting_agent_process_broker`,
  `NativeMessagingHost.app/Contents/MacOS/native_messaging_host`) — so remote access never breaks

The invariant: **every remote-access path must be in the bypass list**, because
ExpressVPN's split-tunnel bypass on macOS is *opportunistic* — if the tunnel
can't reach its endpoint on the current network, traffic through it stalls.
A remote-access tool that depends on the VPN tunnel cannot be relied on for
remote recovery from that stall.

The transfer client is bound to the active ExpressVPN tunnel
interface and address. If ExpressVPN reconnects with a different tunnel, the
client may stop transferring. That is deliberate: it fails closed rather than
falling back to Wi-Fi or Tailscale.

`vpn-guard` remains the safety layer for unsafe states. It checks ExpressVPN,
hotspot state, client reachability, and PF rules.

Network containment is incident-scoped. The guard journals the exact hashes
that were active before it stops them, without changing the operator's separate
`transfer-desired` pause intent. After recovery it starts only that journaled
set. A transfer that was already paused is never auto-started.

`darkmesh-healthcheck` is the remote-access safety net. One launchd-owned
`--watch` instance probes every 20s: VPN state, raw IP, a real fetch by name,
system DNS, Tailscale, and (when installed/required) Chrome Remote Desktop.
When the connected VPN path fails after its grace window, it disconnects the
VPN and automatic reconnect stands down for one hour unless the operator runs
`darkmesh up`. When DNS remains dead off-tunnel, a bounded recovery ladder can temporarily
promote the active service's working DHCP DNS through a fixed root helper. The
helper records and restores the exact prior DNS configuration on network change.
Per-fault circuit breakers stop repeated remedies and surface one alert instead
of thrashing. Status schema 4 is written to `/tmp/darkmesh-status.json` and
publishes a 60-second freshness limit.

The healthcheck emits progress at the start of every tick. The signed infrastructure
supervisor treats 90 seconds without progress as a hung whole tick, escalates from
`SIGTERM` to `SIGKILL`, and restarts the collector.

The healthcheck exists because ExpressVPN's split-tunnel bypass is not a
hard guarantee — on some networks, ExpressVPN's tunnel uses IPs in
`100.64.0.0/10` that collide with Tailscale's tailnet range, and ExpressVPN's
SplitTunnel extension can reject bypass-listed flows. Rather than trying to
eliminate every failure mode (impossible without ExpressVPN-side changes), we
detect the failure and recover automatically.

### Recovery ordering

Darkmesh is the only owner of ExpressVPN connection ordering. ExpressVPN's
built-in autoconnect is off. Network changes are debounced, and retry deadlines
are absolute, so a burst of interface and DNS notifications cannot accelerate
connection attempts.

The reconnect loop distinguishes positive captive evidence from unavailable
global probes. A redirect or portal body holds the VPN down for sign-in. When a
default route exists but Apple, Google, and named probe hosts are unavailable
without portal evidence, Darkmesh makes a bounded VPN attempt. This supports
filtered regions where the VPN is needed for usable internet.

Every automatic standdown and VPN-path failure uses
`darkmesh-restore-plain-network`: transfer ports are contained first, ExpressVPN
autoconnect and Network Lock are disabled, helper-owned DNS is restored,
Tailscale DNS acceptance is disabled, and DHCP DNS is preferred. Tailscale stays
running but is never required for laptop internet or VPN recovery. See
[`docs/network-resilience-state-machine.md`](docs/network-resilience-state-machine.md).

On macOS, Tailscale can remain nominally online while the system silently loses
its `100.64/10` tunnel route after a physical-network change. While ExpressVPN
is disconnected, Darkmesh detects that exact condition and performs a bounded
restart of the saved Tailscale VPN service after three failed samples. The
repair preserves the existing identity and preferences and has a one-hour
automatic retry cooldown. An operator can run `darkmesh repair-tailscale` for
the same checked repair on demand.

An applied Tailscale-required posture, or `protect-tailscale=on` on a headless
host, is continuously enforced. After three confirmed misses, Darkmesh contains
the transfer client, lets ExpressVPN yield, restores Tailscale, and blocks an
optional VPN reconnect until the operator explicitly runs `darkmesh up`. If
`WantRunning` was cleared, the guarded repair uses settings-free `tailscale up`
and verifies the saved
identity and preferences afterward. It never logs out, resets, runs
`tailscale down`, or quits Tailscale. A protected host refuses a posture that
forbids Tailscale.

`server_monitor` should be a UI/status consumer only. It should not own network
policy. Reading `/tmp/darkmesh-status.json` is sufficient to render a
GO / DEGRADED / NO-GO indicator.

For a versioned desired/observed profile surface and optional read-only peer
health, use `darkmesh posture`. Its explicit `apply` boundary preserves the
existing recovery owner and never enables Network Lock. See
[`docs/network-posture-contract.md`](docs/network-posture-contract.md).

`posture set` changes only the selected profile. A successful `posture apply`
records the continuously enforced profile separately, so a failed transition
cannot silently replace the last working contract.

### Menu-bar status (SwiftBar)

A SwiftBar plugin at `swiftbar/darkmesh.10s.sh` renders a glanceable status icon
in the macOS menu bar. Verdict colors: 🟢 GO, 🟡 DEGRADED, 🔴 NO-GO, ⚪️ IDLE.
The dropdown shows ExpressVPN state, the four probe results, the last
auto-disconnect (if any), and quick actions (Connect/Disconnect, run
healthcheck, emergency restore, open ExpressVPN/Tailscale GUIs).

Install:

```bash
brew install --cask swiftbar
scripts/install-user-tools          # auto-installs the plugin when SwiftBar is present
open -a SwiftBar
```

The plugin refreshes every 10s by reading `/tmp/darkmesh-status.json`. It does
no network probes itself — all data comes from the healthcheck LaunchAgent.

### Native menu-bar integration (server_monitor)

The companion `server_monitor` Swift menu-bar app has a `DarkmeshStatusView`
panel that renders the same data natively. It requires Xcode to build; see
`docs/server-monitor-integration.md` for the build and installation flow.

## Quick Checks

```bash
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl status
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl get split-app
/Applications/Tailscale.app/Contents/MacOS/Tailscale netcheck
transfer-vpn-doctor
darkmesh-healthcheck                     # read-only one-shot JSON on stdout
cat /tmp/darkmesh-status.json            # current verdict (LaunchAgent updates every 30s)
vpn-guard.sh
```

## Coexistence experiments

`darkmesh experiment` provides a mutation-free planner, read-only preflight,
adaptive staged campaign, and local report:

```bash
darkmesh experiment start
```

Peer addresses and SSH aliases come from the untracked mode-`0600`
`~/.config/darkmesh/experiment.conf`. The guided command creates that file
interactively when needed, prints the plan, pauses transfers, runs preflight,
requires an exact live-change confirmation, executes the campaign, and prints
the report. The campaign never starts a transfer or changes
ExpressVPN background mode. See
[`docs/runbook.md`](docs/runbook.md#staged-coexistence-experiments) before any
live run. The captive profile intentionally stops for portal sign-in and
provides an explicit `--resume` command for controlled rearm afterward.

One-time privileged recovery setup (fixed verbs only, never a general root shell):

```bash
sudo scripts/install-root-helper.sh "$(id -un)"
```

## Tailnet DNS setting

Tailscale's MagicDNS forwards to upstream DNS servers. If those defaults
overlap with ExpressVPN's tunnel range (`100.64.0.0/10`), DNS forwarding will
silently fail when VPN is connected. To avoid that:

This laptop always uses `tailscale set --accept-dns=false`. Tailnet DNS policy
may still be configured for other devices, but Tailscale DNS is not part of this
machine's ordinary-internet recovery path. Off tunnel and during captive sign-in,
the current network's DHCP DNS remains authoritative.

Another VPN client can leave a dead resolver ahead of DHCP even when ExpressVPN
is disconnected. darkmesh classifies that by behavior rather than ownership: if
system DNS fails, a suspicious VPN-range resolver is present, and the current
DHCP resolver answers directly, it temporarily promotes those DHCP servers. It
does not kill or reconfigure the unrelated VPN client.

Expected (relaxed mode — connectivity is paramount; see `docs/availability-recovery-plan.md` §1):

- ExpressVPN connected (best-effort; the captive-aware reconnect watchdog brings it
  up only when open internet is present, so it never blocks a captive portal).
- Network Lock **OFF**. Fail-closed for the transfer client comes from its
  VPN-interface socket binding + the vpn-guard PF rules — **not** Network Lock,
  which can trap *general* internet on a tunnel hiccup. Only the transfer client is
  ever blocked; the browser, Chrome Remote Desktop, and general traffic never are.
- Split Tunnel enabled.
- Split app list bypasses **Tailscale and Chrome Remote Desktop** (so remote access
  survives the VPN), and **never** the transfer client.
- Tailscale netcheck has `UDP: true` and DERP latency results.
- `transfer-vpn-doctor` says the client binding matches the current ExpressVPN
  tunnel.
- `vpn-guard.sh` reports `SAFE` when ExpressVPN is connected and the current
  network is not a hotspot. A manual transfer intent of `paused` remains paused
  even in that safe network state.

## Reproduce On Another Mac

Install the Homebrew package:

```bash
brew install jlmalone/tap/darkmesh
```

Configure the signed supervisor and packet-filter protection:

```bash
darkmesh setup
darkmesh audit
```

Run `darkmesh setup --legacy-agents` only on a machine without the companion
Server Monitor app. Contributors working from a checkout can install its scripts
directly with `scripts/install-user-tools`.

Apply or verify the ExpressVPN / Tailscale split-tunnel setup:

```bash
darkmesh-expressvpn-tailscale apply
```

If macOS asks for Network Extension approval, approve ExpressVPN's
`SplitTunnelProxyExtension` in:

System Settings > General > Login Items & Extensions > Network Extensions

Darkmesh and `expressvpnctl` can configure the bypass list and request
activation, but they cannot approve a pending system extension on an unmanaged
Mac. `systemextensionsctl list` reports this gate as `activated waiting for
user`. Repeatedly enabling Split Tunnel does not bypass the gate; ExpressVPN may
turn the setting off again until approval succeeds.

Chrome Remote Desktop may show the approval sheet with blank or redacted rows.
If that happens, complete the approval from the Mac's physical keyboard and
display. Silent approval requires a user-approved device-management policy and
is not a Darkmesh setup shortcut. Keep ExpressVPN disconnected until the
extension reports `activated enabled`, then perform the reconnect test with a
known plain-network rollback path.

Then verify:

```bash
darkmesh-expressvpn-tailscale verify
transfer-vpn-doctor
```

If the transfer client is already installed, quit it before refreshing its
binding:

```bash
transfer-vpn-doctor --fix --quit
```

The helper refuses to bind the client unless ExpressVPN is connected and the
ExpressVPN tunnel is identifiable. Network Lock is **not** required — relaxed
mode; fail-closed comes from the socket-binding + PF, not Network Lock.

## Configuration: environment-specific values (not tracked)

darkmesh drives any WebUI-controllable transfer client, but which client you run, and
its app / process / API specifics, are particular to your machine. To keep this project
generic, and to keep any one operator's setup out of a public repo, the tracked scripts
ship only neutral placeholder defaults and load the real values from an **untracked**
file:

```bash
cp transfer-client.conf.example ~/.config/darkmesh/transfer-client.conf
$EDITOR ~/.config/darkmesh/transfer-client.conf
```

`transfer-client.conf.example` documents every field with a deliberately vague
placeholder. Nothing in it is a secret (the WebUI password stays in the macOS Keychain
under `vpn-guard-client`); the values are simply environment specific, so they live out
of version control. If the file is absent the scripts still run, against the neutral
defaults.

Automatic incident recovery also requires positive trust for the current Wi-Fi.
While connected to a network you explicitly trust, enroll its gateway identity:

```bash
darkmesh-transfer trust-current
```

The untracked mode-`0600` allowlist is
`~/.config/darkmesh/trusted-transfer-networks`. Trust is not inferred from the
absence of hotspot evidence. Until a network is enrolled, containment remains
active and the incident journal is preserved.

If operator intent was left paused but the existing stopped set must remain
unchanged, repair only the intent before selecting items in the client:

```bash
darkmesh-transfer activate
```

Unlike `resume`, `activate` never starts the full stopped set.

**Contributors:** please never commit a real transfer-client product name, a host name,
or file-distribution vocabulary specific to one workload. This repo and its full git
history are kept euphemized on purpose, so the project stays generic and one person's
setup is not baked into a public tool. Use the neutral `CLIENT_*` tokens in code and let
them resolve from the untracked config. ExpressVPN and Tailscale are named openly
throughout: they are the subject of the toolkit, not the sensitive part.

One other per-host knob: `protect-tailscale` makes Tailscale the required
remote-access path. It is decided at setup by chassis, on for a headless node
where the tailnet is the command lifeline and off for a laptop where an operator
is present. On a confirmed failure, the reconnect owner contains transfers,
lets the optional VPN yield, and runs guarded Tailscale recovery. Override with
`~/.config/darkmesh/protect-tailscale` containing `on` or `off`.

See [`docs/TRUSTED_MACHINE_CONTEXT.md`](docs/TRUSTED_MACHINE_CONTEXT.md) for keeping
private agent context, runtime configuration, credentials, and operational data in the
correct places when provisioning another trusted machine.

## Helpers

### `scripts/darkmesh-experiment`

Runs the convergence-based WireGuard and Lightway coexistence suite with exact
state snapshots, per-case results, independent deadmen, and verified recovery.
OpenVPN is excluded. `darkmesh coexistence-trial` is a compatibility wrapper;
the old autonomous protocol trial is retired.

### `scripts/darkmesh-expressvpn-tailscale`

Manages the ExpressVPN / Tailscale coexistence layer.

```bash
scripts/darkmesh-expressvpn-tailscale status
scripts/darkmesh-expressvpn-tailscale apply
scripts/darkmesh-expressvpn-tailscale verify
```

It configures background mode, disables ExpressVPN autoconnect, enables split
tunneling, and bypasses **Tailscale and Chrome Remote Desktop** so remote access
survives the VPN. It hands connection intent to Darkmesh instead of connecting
ExpressVPN directly.
Network Lock is left **off** (relaxed); `apply --strict` opts into Network-Lock-on.

### `scripts/transfer-vpn-doctor`

Explains why the transfer client is stuck when ExpressVPN changes its tunnel.

```bash
transfer-vpn-doctor
transfer-vpn-doctor --fix
transfer-vpn-doctor --fix --quit
```

`--fix` updates the client's saved tunnel binding only when ExpressVPN is
connected and the ExpressVPN tunnel is unambiguous. Network Lock is not required
in relaxed mode; `--fix` proceeds with a note when it is off.

Client-specific identifiers are loaded from the untracked
`~/.config/darkmesh/transfer-client.conf`; they are not encoded in source.

## Docs

- [Investigation log](docs/investigation-log.md) — dated record of *why* darkmesh looks the way it does. Read this first if something seems weird; the past decisions are explained there.
- [Threat Model](docs/threat-model.md)
- [macOS ExpressVPN + Tailscale](docs/macos-expressvpn-tailscale.md)
- [Transfer Client Fail-Closed Binding](docs/transfer-client-fail-closed.md)
- [server_monitor Integration](docs/server-monitor-integration.md)
- [Runbook](docs/runbook.md)
- [LLM second-opinion prompt](docs/llm-second-opinion-prompt.md) — self-contained context to seek an independent challenge of the analysis.
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## Relationship To Existing Gists

This project should be the canonical explanation.

- `darkmesh` should point here for ExpressVPN + Tailscale coexistence.
- `vpn-guard` should point here for transfer-client enforcement and state
  reporting.
- `server_monitor` should consume state from `vpn-guard`, not reimplement the
  policy logic.

## Important Warnings

Do not bind the transfer client to the physical Wi-Fi or Ethernet interface.
The active Wi-Fi device varies by machine and hardware generation. Derive it via
`networksetup -listallhardwareports` rather than hardcoding. The transfer
client must be bound to the active ExpressVPN `utun` interface (see
`transfer-vpn-doctor`).

Network Lock is **off** by default (relaxed mode): fail-closed for the transfer
client comes from its tunnel socket-binding + the vpn-guard PF rules, not Network
Lock. Only `darkmesh-expressvpn-tailscale apply --strict` turns Lock on.

Do not add the transfer client to ExpressVPN split-tunnel bypass rules.

Do not treat port-based PF rules as proof that all client traffic is blocked.
They are defense in depth. The client's tunnel socket-binding is the primary
control (Network Lock is off in relaxed mode).

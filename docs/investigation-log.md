# darkmesh investigation log

A dated record of *why* darkmesh looks the way it does. Append future
sessions as new `## YYYY-MM-DD` sections rather than rewriting history,
so the reasoning behind past decisions stays intact.

---

## 2026-07-15: cafe Wi-Fi recovery flap and filtered-region gate

On a new cafe network, a few global-probe successes caused a VPN attempt. DNS and
end-to-end access then failed, the healthcheck disconnected the VPN, and the
reconnect loop entered captive standdown without restoring the plain DNS path.
Tailscale remained online but its DNS acceptance contributed to the unusable
resolver state. Disabling that DNS integration restored ordinary internet.

The reconnect log also showed that network-change signals interrupted 80-second
and 160-second retry waits after only a few seconds. VPN and DNS transitions
generated more signals, so the recovery loop accelerated its own retries and
eventually restarted ExpressVPN.

The fix introduced one idempotent plain-network helper used by automatic and
manual recovery, permanent Tailscale `accept-dns=false` on the laptop, absolute
retry deadlines, signal coalescing, and positive-evidence captive detection.
Networks with a default route but blocked global probes now receive a bounded VPN
attempt. ExpressVPN built-in autoconnect is disabled so Darkmesh owns ordering.

Contract: `docs/network-resilience-state-machine.md`.

## 2026-05-22 — ExpressVPN + Tailscale "internet dies when VPN connects"

### Trigger
On `host-a` (a headless Apple Silicon Mac), connecting ExpressVPN
caused every browser tab, remote session, RDP/CRD connection, and
SSH-over-Tailscale to die within seconds of VPN reaching `Connected`. Disconnecting
the VPN restored everything. Tailscale's menu-bar debug view showed
"DNS Unavailable: dns-forward-failing".

A reference laptop on the same Tailscale tailnet did *not* exhibit this
failure, which proved the combination was workable on another host.

### Initial darkmesh design (what we started with)

The pre-existing design (see `docs/runbook.md`):

- ExpressVPN's split-tunnel was configured "All Other Apps: Use VPN"
- Tailscale's app + system extension were in the **bypass** list
- Network Lock was disabled (relaxed mode)
- the transfer client was socket-bound to ExpressVPN's `utun` for fail-closed leak protection
- `vpn-guard.sh` paused the transfer client and loaded PF block rules when VPN dropped or on hotspot SSIDs

Assumption baked in: ExpressVPN's per-app split-tunnel bypass would actually bypass Tailscale.

### What I observed (with new diagnostic capture)

I wrote `scripts/darkmesh-diag` — a non-interactive capture script with a deadman
switch, safe over flakey remote SSH. It snapshots ExpressVPN state, routes,
interfaces, DNS resolvers, Tailscale state, and reachability probes at
`PRE-VPN / +5s / +15s / +25s / POST-DISCONNECT` boundaries, then captures the
unified log for ExpressVPN + Tailscale processes.

Two runs (local logs matched `/tmp/darkmesh-diag-*.log`) showed:

**Finding #1 — IP-range collision.** ExpressVPN's Lightway tunnel used an
address and resolver inside `100.64.0.0/10`. Tailscale claims that same CGNAT
range for the tailnet. When ExpressVPN connects, the OS can route the injected
resolver via Tailscale's `utun`, where Tailscale finds no corresponding peer
and drops the packet. From the Tailscale extension's
log:

    dns udp query: waiting for response or error from [<vpn-resolver>]: context deadline exceeded
    open-conn-track: timeout opening (TCP <tailnet-address>:<port> => <vpn-resolver>:53); no associated peer node

**Finding #2 (initial; later corrected) — SplitTunnel rejects bypass flows.**
The `com.expressvpn.vpn.splittunnel.cli` log showed:

    provider rejected new flow UDP io.tailscale.ipn.macsys[...] local port 51605 interface en1(bound), remoteEndpoint = 203.0.113.10:3478

I read "rejected" as "blocked," concluding ExpressVPN's bypass mechanism was
itself broken. **This was probably wrong.** See "second opinion" below.

### Attempts that didn't fix the failure

1. **Added Chrome Remote Desktop binaries to the ExpressVPN bypass list.**
   `remoting_me2me_host`, `remoting_me2me_host_service`, `remoting_agent_process_broker`,
   `native_messaging_host` — all `/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app/...`.
   Necessary for the *spec* (CRD as remote-access tool needs to bypass VPN), didn't
   address the root cause.
2. **Pruned the stale Tailscale 1.86.2 extension entry from the bypass list.**
   Cosmetic cleanup; macOS was still using v1.96.5.
3. **Tailnet-wide DNS override** in `https://login.tailscale.com/admin/dns` to
   `1.1.1.1, 9.9.9.9` with "Override local DNS" enabled. The user applied this
   live. **It did not fix the failure** — because ExpressVPN injects DNS at the
   system-resolver layer, *below* where the Tailscale override applies.

### Implemented mitigation: healthcheck + auto-revert

Wrote `scripts/darkmesh-healthcheck` running as a LaunchAgent in `--watch` mode.
Probes every 10s for ExpressVPN connection state, internet reachability via
`ping 1.1.1.1`, DNS via `host example.com`, and Tailscale DERP via `tailscale netcheck`.
When VPN is `Connected` past a 15s grace window and either DNS or internet
is broken, it auto-runs `expressvpnctl disconnect`. Status JSON at
`/tmp/darkmesh-status.json`.

Initial logic bug: classified `internet=true, dns=false, tailscale=true` as
`DEGRADED` (no auto-revert) instead of `NO-GO`. Fixed: any DNS failure with VPN
connected is `NO-GO`. Verified working at 15:00 — VPN connected, healthcheck
caught it, disconnected at +29s, machine healthy at +40s.

### Second opinion (from another LLM)

User asked me to write a self-contained prompt for a second-opinion LLM. That
prompt is saved at `docs/llm-second-opinion-prompt.md`. The second opinion
corrected two of my conclusions and provided the breakthrough:

1. **"provider rejected new flow" probably means *passthrough*, not block.** Apple's
   `NETransparentProxyProvider` semantics: returning `false` from `handleNewFlow`
   says "I'm not handling this, the OS routes it normally." ExpressVPN's
   SplitTunnel is almost certainly that type. Definitive disambiguation
   requires packet capture; we never did it.
2. **ExpressVPN documents that DNS goes through ExpressVPN regardless of split-tunnel
   settings.** This is the *actual* explanation for Tailscale's DNS failing. The
   bypass list correctly bypasses Tailscale's traffic; it cannot bypass DNS.
3. **Tailscale officially documents this CGNAT collision class:**
   `https://tailscale.com/docs/reference/troubleshooting/network-configuration/cgnat-conflicts`
   with `tailscale set --accept-dns=false` and `tailscale set --disable-ipv4`
   as recommended mitigations.

### The systematic test: `darkmesh-protocol-trial`

User had to leave; said "run a long series of tests and attempts, plan for the agent
losing connectivity." I built `scripts/darkmesh-protocol-trial` — an autonomous
test harness, run detached via `nohup`, with absolute deadman + per-test
escalating recovery (disconnect → networklock off → tailscale bounce →
kill processes), so the machine can never get stuck even if the trial itself crashes.

The trial ran 12 tests across 3 phases. Results in
`/tmp/darkmesh-trial-results.json`:

**Phase 1 — protocol matrix on the provider's Smart region:**

| Protocol     | Tunnel addr          | DNS pushed             | Outcome     |
|--------------|----------------------|------------------------|-------------|
| wireguard    | private `10/8` address | CGNAT resolver       | BROKEN-DNS  |
| openvpnudp   | private `10/8` address | CGNAT resolver       | BROKEN-DNS  |
| openvpntcp   | private `10/8` address | CGNAT resolver       | BROKEN-DNS  |
| lightwayudp  | (never connected)    | n/a                    | TIMEOUT     |
| lightwaytcp  | **CGNAT address**     | CGNAT resolver         | BROKEN-DNS (worst: tunnel + DNS both collide) |

**Confirmed**: ExpressVPN pushed a resolver inside `100.64.0.0/10` *regardless of
protocol*. The protocol choice only changed the tunnel subnet (`10/8` for
WireGuard/OpenVPN, 100.64.x for Lightway). The DNS injection is protocol-independent.

**Phase 2 — wireguard across 5 regions:** All BROKEN-DNS. Region doesn't matter.

**Phase 3 — Tailscale-side mitigations with wireguard:**

| Mitigation                              | DNS resolvers          | Outcome    |
|-----------------------------------------|------------------------|------------|
| `tailscale set --accept-dns=false`      | CGNAT + DHCP resolvers | **HEALTHY** |
| `tailscale down` (sanity check)         | CGNAT resolver         | DEGRADED   |

**Why `--accept-dns=false` works:** with Tailscale's MagicDNS subscription off,
Tailscale no longer claims top-priority position in macOS's resolver list. The
OS sees the injected CGNAT resolver (broken) *and* a working DHCP resolver,
then falls back to DHCP when the injected resolver times out. With Tailscale's
MagicDNS *enabled*, `100.100.100.100` is first and the OS doesn't fall back —
it just reports DNS dead.

### The winning configuration

- ExpressVPN protocol: **wireguard** (persistently set via `expressvpnctl set protocol wireguard`).
- Tailscale: `--accept-dns=false` *only while VPN is connected*. Restored to
  default `true` when VPN disconnects. Implemented as an auto-toggle in
  `darkmesh-healthcheck`'s state-transition handler.

Trade-off: while VPN is on, Tailscale MagicDNS hostnames (e.g. `ssh headless-node`)
don't resolve. SSH-by-IP (`ssh node-ip`) still works. If we want
hostnames during VPN-on, `/etc/hosts` entries for the tailnet nodes are the
zero-cost answer; pull them from `tailscale status --json` periodically.

### Healthcheck role going forward

The auto-toggle is the primary fix. The auto-disconnect is still the safety
net for *other* failure modes (a local network blocks the protocol, ExpressVPN
endpoint down, etc.). Both live in the same script.

### Open puzzle: reference-laptop anomaly

The reference laptop does not exhibit this failure on the same Tailscale tailnet.
We never ran the diagnostic on it. Hypothesis: the laptop either (a) uses
LightwayUDP successfully and never hits the protocol-fallback path, (b) is on
a network where ExpressVPN doesn't push a CGNAT resolver, or (c) has a different
ExpressVPN client version with different DNS behavior. If you ever care to
close this loop: install darkmesh-diag on the reference laptop (`scripts/install-user-tools`),
run `darkmesh-diag --window-seconds 60`, compare the captured DNS resolver
list with the headless host's.

### Artifacts created in this session

- `scripts/darkmesh-diag` — non-interactive failure-state capture with deadman
- `scripts/darkmesh-healthcheck` (+ LaunchAgent at `vpn-guard/com.user.darkmesh-healthcheck.plist`) — periodic probe + auto-disconnect + accept-dns auto-toggle
- `scripts/darkmesh-protocol-trial` — autonomous test harness, finds the
  working config across protocols/regions/mitigations
- `docs/llm-second-opinion-prompt.md` — self-contained prompt to seek
  challenge of analysis from another LLM (or future engineer)
- `docs/investigation-log.md` (this file)
- README updated to reflect bypass list (now includes CRD) and the healthcheck role
- `scripts/darkmesh-expressvpn-tailscale apply` extended to auto-discover and
  bypass CRD binaries and prune stale bypass entries

### Decisions that future-me should not relitigate without new data

- **Do not assume the bypass list bypasses DNS.** ExpressVPN intercepts DNS regardless.
- **Do not use LightwayTCP as the chosen protocol.** Its tunnel subnet collides
  with Tailscale's 100.64/10 *in addition to* the DNS injection.
- **Do not rely on tailnet-wide admin DNS override alone.** ExpressVPN's DNS
  is pushed below that layer.
- **Do not write interactive ops scripts.** This user has flakey remote access
  and uses `nohup`-style detached runs. See `feedback_operational_minimalism`
  in memory.

### Things to revisit if behavior changes

- New ExpressVPN client version: re-run `darkmesh-protocol-trial`. They may
  change which DNS server they push, or stop pushing DNS for bypass apps.
- Tailscale releases an OS-level DNS scoping fix for the CGNAT collision: their
  recommendation may shift from `--accept-dns=false` to `--disable-ipv4` or a
  new flag.
- Network conditions change: one test network blocked LightwayUDP. A
  different network may negotiate UDP cleanly and the protocol matrix may need
  to be re-run.

---

## 2026-06-22 — foreign VPN resolver disproves the fallback assumption

The headless test host again had working raw IP connectivity and completely dead
system DNS. Turning MagicDNS off did not expose a healthy DHCP resolver as the
earlier analysis predicted. Resolver #1 remained inside `100.64.0.0/10` with search
domain `openvpn`, injected by a separate OpenVPN-based client while the managed
ExpressVPN client was using WireGuard. All network services reported no static
DNS configuration; the working `8.8.8.8, 64.6.64.6` values were underneath as
DHCP data.

Temporarily setting the active Wi-Fi service to those DHCP-provided values made
system DNS resolve immediately. The CRD endpoint changed from HTTP 000 to a real
HTTP response and its host process re-registered. The foreign resolver remains
visible, so the temporary service override is currently masking it.

Two copies of `darkmesh-healthcheck --watch` were also running. Both held the
old in-memory retry state and periodically forced `accept-dns=true`, repeatedly
recreating the dead path. The watchers were stopped on the affected node while
the corrected implementation was built.

Consequences now encoded in the implementation:

- one launchd watcher is enforced by a PID lock;
- one-shot probes cannot mutate status, breakers, DNS, or VPN state;
- resolver recovery is based on observed health, not assumed product ownership;
- the fixed root helper can promote only the active service's current DHCP DNS
  and records the exact prior configuration for rollback;
- interface, gateway, or DHCP-DNS change triggers restore before further action;
- persistent breakers and reconnect budgets survive process restart and reboot;
- the legacy panic path no longer deletes the live Tailscale CGNAT route or
  enables MagicDNS during a poisoned-resolver state.

## 2026-06-23: captive portal blocked by a stale install (the laptop never received the captive stand-down)

### Trigger

On a public-venue captive Wi-Fi the sign-in portal would not load ("the webpage
couldn't be loaded"), and the macOS captive popup never appeared. Connectivity
only returned after manually running `emergency-restore-internet` and the legacy
`--undo`.

### What the logs showed

The reconnect watchdog was behaving correctly, standing down every cycle:

```
no open internet (captive/offline) - standing down so sign-in works
```

But the healthcheck on the same machine was fighting it, on a roughly 35-second
loop:

```
DNS dead while VPN down for 127 checks -> triggering DNS recovery
dns-recover: ran privileged reset
auto-toggle: tailscale set --accept-dns=true (resolver cleared, DNS healthy)
```

That `accept-dns=true` repinned system DNS to the tunnel-range resolver
(inside `100.64.0.0/10`), which is unreachable on a captive network before sign-in. With
DNS pointed at a dead resolver, the portal domain could not resolve, so neither
the captive probe nor the sign-in page could load.

### Root cause: deployment drift, not a design gap

The captive stand-down already existed in the tree (the 2026-06-22 hardening):
the healthcheck reads the reconnect watchdog's `captive-standdown` phase and
returns `verdict=CAPTIVE`, which short-circuits ahead of any DNS recovery or
auto-disconnect. But the affected machine was still running an older installed
copy that predated that work. The reconnect watchdog had been updated (so it
stood down) while the healthcheck had not (so it kept forcing `accept-dns=true`).
One guard standing down is not enough: every guard that can touch DNS or the VPN
must stand down on a captive network, or the portal stays blocked.

### Fix

Installed the current healthcheck and reconnect (and the breaker library the
watch loop sources at startup) onto the affected machine, and removed the retired
user-level DNS-recover helper whose policy reenabled MagicDNS while the VPN was
down. Verified:

- the healthcheck returns `verdict=CAPTIVE` and performs zero DNS mutation when
  the reconnect sidecar reports `captive-standdown`;
- the current healthcheck never sets `accept-dns=true` at all (the probe-gated
  MagicDNS "restore" that caused the repin is gone); MagicDNS is only ever turned
  off, and off-tunnel DNS stays on the network's DHCP resolver so the portal
  resolves;
- the watch agent stays up and the VPN stays connected through the swap.

### Lessons encoded

- Connectivity is paramount: on a captive or untrusted network the healthcheck
  and the reconnect watchdog both stand down. The healthcheck's `CAPTIVE` verdict
  is the first branch evaluated, ahead of every NO-GO path.
- DNS is DHCP off-tunnel and is never pinned to a tunnel-range resolver. The
  healthcheck no longer owns a "restore MagicDNS" step; it can only turn
  `accept-dns` off.
- A fix in the tree is not a fix on the machine. This failure was pure install
  drift: the corrected code shipped on 2026-06-22 but the node ran the prior
  copy. Audit installed versions, not just the repo, after a hardening change.

### Follow-up (open)

The LaunchAgent template for the healthcheck hardcodes `--protect-tailscale`.
That flag is correct for a headless node where the tailnet is the only way in (a
Tailscale miss should drop the VPN), but wrong for a laptop with an operator
present, where it causes VPN flapping. Re-running the full installer on a laptop
re-adds the flag and regresses that. Make `--protect-tailscale` per-host (opt in
for headless nodes) so the installer is safe to run everywhere. Until then,
deploy to a laptop by installing the binaries and bouncing the existing
LaunchAgent, not by re-templating it.

## 2026-06-24: install-flow hardening (the two follow-ups above, resolved)

Two install-flow bugs surfaced while bringing a long-lived laptop fully green; both
are now fixed so a fresh install of any kind is correct by construction.

### `--protect-tailscale` is now per-host

The healthcheck plist template no longer hardcodes `--protect-tailscale`; it carries a
`__PROTECT_TS__` placeholder. `darkmesh-setup` and `install-user-tools` substitute the
flag in (headless) or delete the placeholder line (laptop) when they template the plist.
The decision is by chassis (an internal battery, via `pmset -g batt`, means a laptop, so
off; no battery means a headless node where the tailnet is the only way in, so on) and is
overridable with `~/.config/darkmesh/protect-tailscale` containing `on` or `off`. The full
installer is now safe to re-run on any node without reintroducing the flapping that 138
auto-disconnects had caused on the laptop.

### The privileged helper is no longer silently skipped

A node was found yellow because the root recovery helper
(`/Library/darkmesh/bin/darkmesh-root-helper`) and its scoped NOPASSWD sudoers had never
been installed. Root cause: it was provisioned via `install-user-tools`, whose privileged
step only tried passwordless `sudo -n` and, when that failed, printed an easily-missed
"ACTION NEEDED" and moved on. The canonical `darkmesh setup` already installs the helper as
a mandatory first step and refuses to arm an incomplete stack, so the gap was only in the
legacy `install-user-tools` path. That path now, at an interactive terminal, runs the
helper install directly (one password prompt) instead of standing down silently, and stays
loud-but-non-interactive only when headless (no TTY). Lesson reinforced: a recovery stack
missing its privileged half should fail loud, never silently.

## 2026-07-03: hotspot detection was blind (SSID hidden by macOS), transfers ran on mobile data

While tethered to a phone hotspot, the transfer client kept downloading; the guard
logged `state: vpn=yes hotspot=no ssid=-` every 30s and kept resuming it. The hotspot
SSID pattern list was correct (the phone's substring was present); detection never saw
any SSID to match.

Root cause: `current_ssid` relied on `networksetup -getairportnetwork`, which on modern
macOS reports "You are not associated with an AirPort network" even while connected.
Every other unprivileged source (`ipconfig getsummary`, `system_profiler`) now prints
`<redacted>` unless the caller has Location Services authorization, which a LaunchAgent
shell script can never have. So `is_hotspot` treated an empty SSID as "not a hotspot":
fail-open on exactly the networks the guard exists to catch.

Fixes, in layers:

1. `current_ssid` tries `networksetup`, then `sudo -n wdutil info` (root still sees the
   SSID; requires the new optional sudoers line), then `ipconfig getsummary`, and
   discards a literal `<redacted>`.
2. `is_hotspot` no longer treats a missing SSID as safe. When traffic egresses over
   Wi-Fi it applies SSID-free tether signatures: the iPhone hotspot subnet
   (172.20.10.0/28), and a locally-administered default-gateway MAC. Phones randomize
   their AP MAC (observed `fe:20:20:53:ee:9c`, LA bit set); home and office routers
   broadcast burned-in vendor OUIs. Verified live on the offending hotspot: detection
   fired via the MAC signal with the SSID unreadable.
3. The pause/resume Web API calls now try the client's v5 endpoint names (`stop`/
   `start`) before the legacy ones (`pause`/`resume`); the renamed endpoints were
   404ing, which silently degraded every pause to the SIGSTOP fallback.
4. Local config gap (untracked): the Web UI base had never been set, so the guard
   talked to the neutral default port and always fell back to SIGSTOP. Real host:port
   now set in the local conf.

Lesson repeated from the sudoers entry above: a guard whose detection input silently
disappears must fail loud or fall back to independent signals, never assume safety.
An OS update can (and did) turn a working detector into a no-op without any error.

## 2026-07-13: ordinary router triggered the hotspot fallback and paused transfers

A normal home router used a locally-administered MAC for its gateway while macOS
redacted the Wi-Fi SSID. The guard treated that single ambiguous signal as decisive,
logged `vpn=yes hotspot=yes`, loaded the PF block, and paused the transfer client every
30 seconds even though the VPN tunnel and client binding were both current.

The broader network health file still reported `verdict=GO`. That verdict correctly
described VPN, internet, DNS, and remote-access health, but Server Monitor did not fold
the already-published `pf_kill_active` state into its combined tint. The result was a
green icon beside an intentionally blocked transfer client.

The fix preserves the conservative unknown-network behavior while adding a narrow
operator override: `~/.config/vpn-guard/trusted-gateway-macs.txt` accepts exact, stable
gateway MACs for known non-hotspot routers. It suppresses only the locally-administered
MAC fallback. An explicit hotspot SSID or known tether subnet is evaluated first and
still blocks. Deterministic tests cover unknown, trusted, subnet, SSID, and ordinary
gateway cases.

Server Monitor now renders an active transfer gate as `Transfers blocked`, includes a
dedicated probe row, and pulls the menu icon off green. Live verification on the
affected network showed the guard transition to `SAFE`, the PF sidecar transition to
`pf_kill_active=false`, and the client return to a connected state.

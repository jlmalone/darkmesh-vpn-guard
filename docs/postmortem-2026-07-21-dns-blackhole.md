# Postmortem: DNS blackhole reported as GO (2026-07-21)

Status: resolved. The P0 liveness and truthful-status tranche is implemented. Safe resolver
ownership remains follow-up work.

## Summary

DNS failed for approximately 26 hours while IP connectivity and the VPN tunnel remained usable.
The global resolvers came from DHCP, but port 53 to those resolvers was unreachable while the VPN
resolver remained reachable. The VPN resolver existed only as an interface-scoped resolver, so
ordinary lookups did not select it.

At the same time, `darkmesh-healthcheck` stopped completing ticks. Its last status said `GO`, and
`darkmesh status` displayed that snapshot without checking its age. The signed supervisor reported
the child healthy because its process was still resident.

The central failure was therefore larger than DNS: a hung observer became a permanent cached green.

## Impact

- New connections requiring name resolution failed.
- Existing connections continued, making the outage appear inconsistent.
- `darkmesh status` contradicted the correctly failing `darkmesh audit`, delaying diagnosis.
- Recovery did not occur until manual intervention approximately 26.7 hours later.

## Timeline

All times are UTC.

| Time | Event |
|---|---|
| 07-20T01:42 | DNS recovery rung disables Tailscale DNS acceptance |
| 07-20T02:19 to 02:23 | DNS recovery reaches `gave-up`; breaker opens |
| 07-20T02:33 | Temporary DNS override is restored; breaker closes |
| 07-20T04:03:43 | Last completed healthcheck line reports fresh `GO` |
| about 07-20T04:04:22 | A subsequent tick starts and never completes |
| shortly afterward | A network-change storm begins |
| next 26.7 hours | Healthcheck PID remains alive; no new snapshot is written |
| 07-21T06:44 | Audit reports a 95,998-second stale file while status prints `GO` |
| 07-21T06:45 | `darkmesh repair` terminates the original healthcheck PID |
| 07-21T06:47 | System resolver is pointed at the reachable VPN resolver; DNS returns |

## Evidence and corrected diagnosis

During the incident:

| Target | Port | Result |
|---|---|---|
| public IP endpoints | 443 | open |
| DHCP/public resolvers | 53 | blocked |
| VPN resolver | 53 | open |

The system's unscoped resolvers were DHCP-supplied. The VPN resolver appeared only in a scoped
resolver entry. Direct queries to the VPN resolver succeeded.

Darkmesh's PF anchor protects transfer ports, not DNS. The measurements are consistent with the
VPN client's DNS leak protection, but retained evidence does not prove which component filtered
port 53. The fix must not depend on that attribution.

Supervisor logs establish that the same healthcheck PID started on 2026-07-19 and remained alive
until repair on 2026-07-21. This disproves process death, PID reuse, and stale-lock refusal as causes
of this incident. The collector hung during a tick.

`Tailscale status --json` was the leading unbounded call and may have blocked on its LocalAPI socket
while the network stack was reconfiguring. That is plausible, not proven. Other external recovery
commands could also block. The permanent control therefore bounds the whole tick by watching
progress from outside the process.

## Root causes

### 1. Resolver ownership was assumed, not enforced

`tailscale set --accept-dns=false` removes Tailscale as a resolver source. It does not select the
VPN resolver. The global resolver then depends on DHCP unless Darkmesh explicitly owns it.

The missing invariant is:

> The unscoped resolvers the OS will query must be reachable under the active network policy.

This is a configuration fault, not a transient DNS fault. The existing flush and MagicDNS ladder
cannot repair a contradiction between the chosen resolver and the active filter.

### 2. The healthcheck had no whole-tick deadline

Individual HTTP and DNS probes had timeouts, but `Tailscale status --json` and recovery commands did
not. One blocked foreground command could stop every later status write.

### 3. Supervision checked presence instead of progress

The infrastructure agent used `Process.isRunning`. Its restart hook sent `SIGTERM` but did not
escalate. Bash may defer a termination trap while waiting on a blocked foreground command, so even
an attempted recycle could remain stuck indefinitely.

### 4. Consumers trusted an immortal snapshot

The shared JSON had a timestamp, but CLI and SwiftBar ignored it. Server Monitor already rejected a
snapshot older than 60 seconds; the earlier postmortem incorrectly said it inherited the green
behavior. The affected green consumers were the CLI and SwiftBar.

## Implemented permanent controls

### Progress watchdog and forced recovery

- The healthcheck writes one stdout heartbeat at tick start.
- Darkmesh configures `maxSilenceSeconds: 90` on that persistent child.
- The signed supervisor watches the child's output log on its own two-second maintenance clock.
- After 90 seconds without output it records PID, silence, and command evidence, sends `SIGTERM`,
  waits five seconds, and sends `SIGKILL` if the process remains alive.
- The existing ten-second restart delay then starts a fresh collector.
- Supervisor status schema 2 publishes `responsive` and `silenceSeconds`. Audit requires both
  managed Darkmesh children to be running and responsive.

The recovery objective is restarted-and-writing in under 120 seconds: 90 seconds silence, at most
two seconds detection delay, five seconds termination grace, ten seconds restart delay, and the
next immediate tick.

### Bounded leading suspect

`Tailscale status --json` has a 12-second deadline plus one-second termination grace. A stuck
Tailscale client now yields `tailscale_ok=false`; it cannot freeze the status writer.

### Truthful status contract

Darkmesh status schema 4 publishes `max_age_seconds: 60`. Age and staleness are derived from both
the authored timestamp and file modification time rather than persisted as values that immediately
decay.

- CLI prints `verdict=STALE`, includes the last verdict and timestamp, and exits nonzero.
- SwiftBar shows `STALE`, never cached green.
- Audit uses the published limit and requires schema 4.
- Server Monitor accepts schemas 3 and 4 during rollout and applies the stricter of its configured
  limit and the published limit.

## Verification

Regression tests cover the incident shape:

1. A Tailscale command that stops indefinitely cannot hold a tick past the test deadline; status
   advances with `tailscale_ok=false`.
2. A persistent child that ignores `SIGTERM` is detected, force-killed, and restarted.
3. A snapshot frozen 26 hours in the past makes CLI and SwiftBar report `STALE`; neither prints GO.
4. Swift and shell builds validate the cross-repository status and supervisor contracts.

## Remaining work, ordered by safety

### P1: detect resolver-policy mismatch

Add a packet-free named fault, `dns_policy_mismatch`, comparing effective unscoped resolvers with
the active reachable/permitted set. Surface and alert first; take no corrective action in the
initial version.

### P1: safely own the VPN resolver

Do not reuse the existing DHCP override journal. A VPN-resolver override needs:

- a separate journal;
- mutual exclusion with DHCP poison recovery;
- an exemption for the elected VPN resolver in suspicious-resolver detection;
- dynamic resolver discovery rather than a fixed address;
- containment of transfer traffic before any VPN disconnect;
- fallback order: contain transfer, disconnect VPN, restore DHCP DNS, then cool down.

Ordinary internet connectivity outranks VPN-everywhere. If the VPN resolver cannot be selected
safely, Darkmesh must restore plain connectivity rather than maintain a general outage.

### P2: durable wall-clock recovery and state migration

Persist ladder timing across process restarts. Move the user-authored snapshot from `/tmp` to
per-user Application Support, not root-owned `/Library/darkmesh/state`, with a coordinated migration
for consumers.

## Operational fallback

The incident was cleared with a manual DNS service override to the VPN resolver. That override is
static and unowned. Until resolver ownership is implemented, `darkmesh panic` remains the safe
fallback because it contains transfer traffic before restoring plain connectivity.

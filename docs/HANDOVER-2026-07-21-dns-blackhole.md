# Handover: DNS blackhole follow-up (2026-07-21)

Read `docs/postmortem-2026-07-21-dns-blackhole.md` first. It contains the corrected evidence,
implemented liveness controls, and remaining design constraints.

## Current state

- The immediate outage is resolved by a manual resolver override to the VPN resolver.
- Status schema 4 publishes a 60-second freshness limit.
- CLI, SwiftBar, audit, and Server Monitor reject stale snapshots.
- The healthcheck emits tick-start progress and bounds `Tailscale status --json`.
- The signed infrastructure supervisor watches opted-in child progress, reports responsiveness,
  and force-kills a child that ignores `SIGTERM`.
- Darkmesh configures a 90-second silence limit. The target from freeze to a restarted collector is
  under 120 seconds.

## Established diagnosis

- Port 53 was unreachable to the DHCP/global resolvers and reachable to the VPN resolver.
- IP and HTTPS connectivity remained available.
- The VPN resolver was scoped and was not the global resolver.
- The original healthcheck PID remained alive across the entire 26.7-hour gap. PID reuse and stale
  lock refusal did not cause this incident.
- The process hung during a tick. An unbounded Tailscale LocalAPI read is the leading candidate, not
  a proven root cause. The whole-tick watchdog covers every external call regardless.
- Darkmesh PF rules do not filter DNS. Do not describe the port-53 block as Darkmesh egress policy.

## Completed P0 acceptance

- A 26-hour-old GO snapshot produces `verdict=STALE` and a nonzero CLI exit.
- SwiftBar shows `STALE`, not green.
- A stopped Tailscale command cannot freeze the writer.
- A SIGTERM-resistant persistent child is force-killed and restarted.
- Supervisor status exposes `responsive` and `silenceSeconds`; audit fails closed on either.

## Next work

### 1. Detect `dns_policy_mismatch`

Compare effective unscoped resolvers with the active reachable/permitted set without sending a
packet. Surface it as a distinct named fault. The first version is detection and alerting only.

### 2. Design VPN resolver ownership behind a default-off flag

Do not reuse `DNS_OVERRIDE_JOURNAL`. The existing override promotes DHCP DNS and would recreate this
incident if used for VPN ownership. The new path requires a distinct journal, mutual exclusion,
dynamic resolver discovery, and an exemption for the elected VPN resolver.

If resolver ownership fails, preserve the governing priority:

1. contain transfer traffic;
2. disconnect the VPN;
3. restore DHCP DNS and ordinary internet;
4. enter cooldown instead of flapping.

### 3. Complete lower-priority durability work

- persist recovery ladder wall-clock state across restarts;
- publish reconnect and PF sidecar ages;
- move user-authored state to per-user Application Support with a compatibility transition;
- replace the directory lock as general hardening, without claiming it caused this incident.

## Do not break

- Ordinary internet and remote access outrank VPN-everywhere.
- Transfer peer traffic remains fail-closed before VPN disconnect or DNS restoration.
- `accept-dns=false` removes Tailscale DNS; it does not select the VPN resolver.
- The shared status schema must be bumped additively and coordinated with Server Monitor.
- No per-script LaunchAgent. Infrastructure work stays under the signed shared supervisor.

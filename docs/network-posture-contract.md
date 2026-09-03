# Network posture control and read-only health contract

`darkmesh posture` is a public-safe control surface for a status consumer such
as Server Monitor. It does not replace the schema-4 `/tmp/darkmesh-status.json`
contract or make Server Monitor a policy owner.

All outputs are JSON envelopes with `schema: 2` and a `kind`. Consumers must
ignore unknown fields and treat an unavailable or newer schema as unavailable,
not as permission to change networking. Existing schema-4 status keys are not
renamed or changed.

## Commands

```bash
darkmesh posture profiles --json
darkmesh posture show
darkmesh posture set tailscale-required-vpn-preferred
darkmesh posture health --json
darkmesh posture topology --json
darkmesh posture probe --json              # explicit bounded active peer checks
darkmesh posture report --json             # combined local read-only peer report
darkmesh posture apply                 # explicit live transition only
```

`set` records a selection in the untracked mode-0600 file
`~/.config/darkmesh/posture.json`. It never touches a network service or changes
the continuously enforced posture. `apply` is deliberately separate. Each
successful apply also records the enforced profile in the mode-0600
`~/.config/darkmesh/posture-enforced.json`; unsuccessful transitions leave the
previous enforced profile intact. Each apply captures the initial status, preflights
transfer containment, runs one bounded plan, observes status until its deadline,
and writes desired posture only after successful postconditions. Failure returns
structured `initial`, `actions`, `postcondition`, and `rollback` evidence. The
plain profile invokes `darkmesh-panic`, then explicitly runs `tailscale down`.
It does not change panic's normal route-preserving behavior. VPN-required plans
use `darkmesh-up`; required Tailscale uses only `darkmesh-repair-tailscale` when
that guarded primitive supports the current conditions. No profile enables
Network Lock.

Every profile includes explicit `required`, `preferred`, `forbidden`, ordered
`priority`, and `degraded` semantics. Internet remains first, and transfer
containment remains scoped and fail-closed. A degraded result never authorizes
a general kill switch or an automatic transition.

`show` also emits an `assessment` over required, preferred, and forbidden
checks. It has a stable `severity` (`green`, `yellow`, `red`, or `gray`) and a
`state`. Required failure or forbidden presence is red; missing preferred
telemetry is yellow; unavailable required telemetry is gray unless an observed
failure already proves red. SSH is deliberately unavailable in `show`, because
it is only determined by the opt-in peer report below.

`show` includes both `desiredProfile` and the additive `enforcedProfile`. A
consumer may therefore distinguish a selection awaiting Apply from the last
successfully converged policy.

A successfully applied Tailscale-required profile is a durable contract. The
healthcheck and reconnect owner continuously consume the enforced profile. On
three confirmed misses, the commercial VPN yields after transfer containment,
required Tailscale is restored, and only then may optional VPN recovery proceed.
The Tailscale failure records a priority standdown, so optional VPN recovery
requires an explicit `darkmesh up` rearm instead of risking a reconnect loop.
The guarded repair can re-arm a stopped `WantRunning=false` backend without
settings flags, then verifies that identity and saved preferences did not
change. A host with `protect-tailscale=on` refuses profiles that forbid
Tailscale.

VPN-forbidden profiles are durable contracts as well. The reconnect owner
atomically restores desired VPN state to `off`, contains the transfer client,
and restores plain networking whenever ExpressVPN reappears. The healthcheck
reports `GO` for that intentional disconnected state only after Internet, DNS,
required Tailscale, required remote desktop, and other safety checks have
passed. A connected VPN under the same contract is `NO-GO`.

The two `optional` profiles never start their optional component and its
absence is yellow. The two `preferred` profiles are secondary-high: absence
is yellow and an explicit apply may make one bounded attempt. A Tailscale-first
VPN attempt rolls back with `darkmesh-panic` if its previously working
Tailscale path regresses. A VPN-first Tailscale attempt is skipped rather than
using an unsafe restart when the guarded repair's plain-network preconditions
do not hold.

`dual-required-zero-general-egress-leak` is capability-gated. Current
Darkmesh has no machine-wide kill switch by design, so apply refuses before
preflight or action with `capability-unavailable`; it never claims leak-proof
application.

The default apply deadline is 60 seconds. When required Tailscale is absent
behind a connected lower-priority VPN, Tailscale-first profiles first restore
the plain path, then use guarded repair; only the secondary-high profile may
make a later bounded VPN attempt. The strict profile publishes
`capabilities.zeroGeneralEgressLeak=false`, and refusal echoes that metadata.
Profiles publish a 360-second consumer deadline so the UI cannot terminate a
multi-step transition or its rollback merely because an individual primitive
uses the 60-second producer deadline.

## Peer topology

Peer probing is opt-in and read-only. Create the ignored local file
`~/.config/darkmesh/posture-peers.conf`, one bounded target per line:

```text
# id target ssh-target-or-- remote-darkmesh-path
host-a host-a host-a /opt/homebrew/bin/darkmesh
host-b host-b -
```

`topology` is deliberately passive so Server Monitor can poll it only while its
lazy Network window is open. It enumerates local interfaces and addresses, then
records effective physical-default, Internet-egress, Tailscale-sentinel,
Tailscale-self, and configured-peer routes. It also includes Tailscale
self/control health, warnings, and cached peer records. It never pings, opens
TCP, or opens SSH.

The Tailscale status document is parsed with a separate bounded machine-data
limit before display fields are capped. Large peer maps must not be truncated
into invalid JSON and misreported as an unavailable local Tailscale node.

`probe` is the explicit active read-only path. For every valid configured peer it
performs a bounded `tailscale ping --c 1 --until-direct=false`, TCP/22 check,
and batch-mode SSH report. Peer records are matched by map key, `HostName`,
`DNSName`, or `TailscaleIPs`, not just their map key. Peer configuration rejects
malformed or incomplete rows rather than probing an arbitrary shell value.
Each local SSH process is niced and the remote command itself begins with
`/usr/bin/nice -n 19`. The optional fourth column selects a validated absolute
remote Darkmesh path per peer; `DARKMESH_REMOTE_PATH` remains the default. The
remote `report` combines desired posture, observed
Internet/VPN/Tailscale state, Tailscale warnings, audit verdict, and transfer
readiness. These commands never write status, change Tailscale, or read
credentials.

Operators may use `darkmesh-ssh-proxy` as an OpenSSH `ProxyCommand`. It prefers
the running Tailscale daemon's `nc` transport, which avoids a stale or competing
system route, and uses one bounded direct socket only when that daemon is not
healthy. Selection occurs before the SSH protocol begins, so remote commands
are never replayed. SSH authentication and host-key verification remain owned
by OpenSSH.

`report` also executes bounded read-only `darkmesh-audit --json` and
`transfer-vpn-doctor --check`, returning their status, capped stdout, and capped
stderr as `audit` and `transferReadiness` evidence.

The strict dual-required profile is intentionally unavailable until a separate
audited machine-wide capability exists. The profile contract never turns the
current scoped transfer containment into a machine-wide egress claim.

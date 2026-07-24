# Self-Healing Hardening, Circuit-Breaker & Fleet Recovery Plan

> **Background registration superseded 2026-07-13:** this remains the recovery
> state-machine record, but separate LaunchAgent and Protection Repair references
> are historical. One Developer ID-signed Server Monitor infrastructure agent now
> owns the supervised/scheduled workload; Server Monitor observes it read-only.

> **Status:** FINAL implementation plan (v2.1).
> **Date:** 2026-06-22.
> **Builds on (do not duplicate):** [`docs/availability-recovery-plan.md`](./availability-recovery-plan.md)
> (the 2026-06-16 plan) and [`docs/investigation-log.md`](./investigation-log.md).
> **Repos:** `darkmesh-vpn-guard` (this repo) + `~/ios_code/server_monitor` (PUBLIC consumer).
> **Public-repo hygiene:** no machine hostnames, no tailnet node IPs, no tunnel IPs, no content names,
> no app bundle ids. ExpressVPN / Tailscale / Chrome Remote Desktop are named (the project is about
> their coexistence). Generic infrastructure ranges already present in tracked code (`100.64.0.0/10` =
> a possible ExpressVPN resolver range, `100.100.100.100` = Tailscale MagicDNS,
> `8.8.8.8`/`64.6.64.6` = common DHCP
> resolvers) may appear; specific node identities may not.

> **Revised 2026-06-22 (v2), substantive changes from v1:**
> - Invariant precedence corrected to **lower-numbered wins** (internet > CRD > leak > nice-to-have >
>   status-light). v1 said "higher wins," which inverted it (§4).
> - **Dropped the autonomous `tailscaled` restart rung**: it would kill the only working lifeline during
>   the incident, and targets a service model the runbook says is not used here (§8, §10).
> - **Single-writer breaker**: `darkmesh-healthcheck` is the only writer of breaker state;
>   `darkmesh-reconnect` keeps its own separate sidecar; the root helper never writes breaker state
>   (§5, §9). Removes the multi-writer/lost-update hazard.
> - **Cycle-based breaker budget** that always traverses the full ladder before giving up; **only
>   recovery actions are suppressed when a breaker opens, probing/status cadence is unchanged** (§9).
> - **Complete verdict decision table** added; "GO when N probes pass" replaced (§7).
> - **Per-fault `breakers` map** in the status schema (was a single object that could not represent
>   simultaneous DNS + CRD faults) (§9, §12).
> - **Root helper minimized** to fixed privileged verbs; DNS ownership/direction policy stays in the
>   user watcher (§10).
> - **CRD probe fixed**: any HTTP status (incl. 4xx) counts as reachable (not `curl -f`); CRD is
>   **optional per node** so non-CRD machines are never permanent NO-GO; the known "host-unregistered"
>   blind spot is stated, not papered over (§6).
> - **server_monitor reuses the existing Protection Repair path**, no new button (§12).
> - **Logging**: also fix the duplicated launchd stderr copy (§11).
> - **Fleet**: untracked allowlist (not tailscale autodiscovery), admin-gated privileged install,
>   canary, version/hash verification, `nice -n 19` on every remote command (§13).
> - **Tests**: deterministic stubs + injectable clock first, then one canary with auto-rollback; no
>   blackholing DNS/CRD across headless nodes (§15).
> - **Foreign resolver poisoning:** the recurrence was ultimately traced to a second VPN stack leaving
>   a dead `100.64.0.0/10` resolver ahead of DHCP DNS. Recovery now tests resolver health rather than
>   assuming ownership, temporarily promotes the active service's DHCP DNS through the root helper,
>   and restores the exact prior service configuration when the poison disappears or the network
>   changes (§2, §8, §10).
> - **v2 review closure:** the verdict table is executable first-match logic; Apple probe body handling
>   is coherent and total probe time is bounded; only the launchd watch instance mutates recovery state;
>   reconnect actions are serialized through a request file consumed by the existing loop; CRD
>   requirement detection and launchd-domain discovery are explicit; launchd stdout/stderr go to
>   `/dev/null` (§5–§7, §10–§11).

---

## 0. TL;DR

The darkmesh self-healing stack **is deployed and running** on the affected headless node and on the
laptop. It still let a node sit with dead DNS until a human diagnosed it. Root cause is three logic
defects in the code that is present (not a missing watchdog):

1. **The privileged DNS recovery moves DNS the wrong way in the state that recurred.** When ExpressVPN
   is wedged "half-up" (connection state not `Connected`, but its CGNAT resolver is still injected
   and its tunnel not carrying traffic), the helper runs `tailscale set --accept-dns=true`, pinning
   MagicDNS to the dead injected upstream. The human fix was the opposite: `accept-dns=false` so the OS
   uses the working DHCP resolver.
2. **No persistent circuit breaker.** The retry budget lives in process memory and resets on restart, so
   nothing tracks "this remedy has run N times in M minutes and still fails, stop and escalate."
3. **The probe battery cannot see the failure end to end.** Internet was checked by IP (which passed),
   DNS by name (which failed), but nothing did an HTTP fetch by name, and **nothing probed Chrome Remote
   Desktop at all**, though "CRD always reachable" is locked invariant #2.
4. **The dead resolver was not owned by the managed VPN.** A separate OpenVPN-based client left a
   resolver in `100.64.0.0/10` with search domain `openvpn` ahead of otherwise-working DHCP DNS. Turning
   MagicDNS off therefore exposed the same dead resolver instead of DHCP. Recovery must classify
   resolver health and safely promote the active service's DHCP DNS; it must not infer ownership from
   the address or tear down an unrelated VPN stack.

This plan fixes the DNS ladder direction, adds a persistent per-fault circuit breaker that bounds and
escalates recovery, adds an end-to-end internet probe and a CRD probe, generalizes the privileged
helper into a minimal fixed verb set behind a scoped NOPASSWD rule, redesigns logging, and makes the
whole thing deploy and verify across the fleet, all under a corrected invariant precedence and a fully
specified verdict state machine.

---

## 1. Trigger incident (2026-06-22)

A headless Mac mini node was unreachable over Chrome Remote Desktop. Tailscale SSH still worked (it
rides cached DERP relay IPs and does not need system DNS), the tell that this is a DNS fault.

On the node: ICMP to the gateway and `8.8.8.8` succeeded and `curl https://1.1.1.1` (by IP) returned
HTTP 301 in 40 ms (**raw IP fine**); `nslookup google.com` via the system resolver timed out while
`nslookup google.com 8.8.8.8` resolved instantly (**name resolution dead**); `curl
https://remotedesktop-pa.googleapis.com` returned HTTP 000 although the CRD host (`remoting_me2me_host`)
and its launchd job were alive (CRD could not heartbeat because it could not resolve the name). System
resolver was `100.100.100.100` (MagicDNS) plus a resolver inside `100.64.0.0/10`; ExpressVPN was
running but the default route was on the wired interface, not a tunnel (the "half-up" state). DHCP DNS
was `8.8.8.8, 64.6.64.6` and worked when queried directly.

Human fix that worked: `tailscale set --accept-dns=false` + flush + `killall -HUP mDNSResponder`. CRD
returned within a minute. Same class as the 2026-06-15 outage, different trigger: last time the VPN was
cleanly `Disconnected`; this time it was wedged half-up, which routes recovery down its wrong branch.

---

## 2. Why it recurred despite the deployed machinery (file:line)

The full stack was present and running on the node. This is a logic gap, not a deployment gap.

1. **Wrong DNS direction for the half-up state.** `scripts/darkmesh-dns-recover:37-42`: if connection
   state is not `Connected`/`Connecting` it runs `accept-dns=true`, handing DNS to MagicDNS, which (with
   an injected CGNAT resolver still present) forwards to a dead upstream. The healthcheck's own restore path is
   careful (`darkmesh-healthcheck:307-315` only flips `accept-dns=true` after
   `! expressvpn_resolver_present && dns_ok`); the privileged helper bypasses that guard.
2. **Recovery only triggers on exact `Disconnected`.** `darkmesh-healthcheck:327-344`: the DNS-recover
   call sits inside the `state == "Disconnected"` branch, so a wedged `Connecting`/unknown state never
   reaches it.
3. **Retry budget is in-memory only.** `darkmesh-healthcheck:241-242,254,338-341`: `DNS_DEAD_TICKS` and
   `LAST_DNS_RECOVER_EPOCH` are loop variables; a restart/crash/reboot resets them, so the cooldown and
   the give-up logic never persist.
4. **No end-to-end internet probe; no CRD probe.** `darkmesh-healthcheck:94-111` checks ICMP/TCP-443 to
   a literal IP (which **passed** during the incident, a false "internet ok"); there is no fetch-by-name
   and no CRD probe, so the verdict never produced a CRD- or fetch-specific NO-GO.
5. **Unbounded, low-signal logging** (§11): 12-14 MB `healthcheck.log` per node, no rotation, one line
   per tick on GO, no action/escalation record.

---

## 3. Requirements added this round (operator, 2026-06-22)

- **R-CRD:** CRD reachability is an active healthcheck aspect.
- **R-NET:** Open-internet reachability (real fetch by name), distinct from raw IP.
- **R-BREAK:** Track repeated failures/remedies in a window; stop repeating, escalate, surface.
- **R-LOG:** Bounded (rotated), level-separated, queryable action/escalation record, fleet-visible.
- **R-SUDO:** Indefinite passwordless privilege for recovery, done safely, fleet-wide; empower darkmesh
  and server_monitor.
- **R-FLEET:** Deployed and verifiable on every Mac, not just where a fire was diagnosed.

---

## 4. Invariants & priority (governing law)

Same invariants as `availability-recovery-plan.md` §1. **Precedence: the lower-numbered (earlier)
invariant wins on conflict** (internet connectivity outranks everything; the status light outranks
nothing).

1. **Internet connectivity is paramount.** No darkmesh action may self-inflict a connectivity block
   (captive portals included).
2. **Chrome Remote Desktop is always reachable.** Secondary only to raw connectivity. *This round turns
   it into a probe (R-CRD) and a recovery rung.*
3. **The transfer client never leaks unprotected.** Socket-binding primary; PF port-scoped backstop.
4. **Most traffic over VPN is nice-to-have.**
5. **"Green" is a status light, never an enforcement trigger.** The only thing darkmesh enforces is #3.

**Bounded-recovery corollary (R-BREAK + the "loops must terminate" rule):** every automated remedy is
bounded. When a fault's ladder is exhausted, darkmesh stops acting on that fault, emits exactly one
coalesced alert, and keeps only *observing* it. darkmesh never thrashes a remedy that is not working and
never repeats an action that needs human/external input to succeed.

---

## 5. Architecture & ownership (single-writer per state)

| Actor | Privilege | Owns (sole writer) | Never does |
|---|---|---|---|
| `darkmesh-healthcheck --watch` (the launchd instance only) | user | all probes; verdict; DNS/CRD recovery sequencing; **the breaker state file**; `/tmp/darkmesh-status.json` (merges sidecars) | run concurrent recovery actors; privileged ops (delegates) |
| one-shot `darkmesh-healthcheck` | user | read-only probe + status preview | breaker writes; recovery actions; alerts |
| `darkmesh-reconnect` | user | VPN availability recovery (connect/un-wedge/rebind); its sidecar + persistent restart budget; consumes serialized requests | write the healthcheck breaker or main status directly; run a second recovery loop |
| `darkmesh-root-helper` | **root** | fixed privileged DNS override/restore/flush and CRD restart; root-owned DNS rollback journal | resolver-ownership policy; breaker writes; free-form input |
| `server_monitor` | user (no root) | nothing; **read-only consumer** + the existing generic Protection Repair path | own network policy; hold sudo; see real tool names |

This is the key structural fix: **one writer per piece of state.** The breaker is written only by the
launchd healthcheck; one-shot probes are read-only; reconnect uses a separate sidecar and is the sole
executor of VPN recovery. The helper writes only its root-owned DNS rollback journal. Atomic temp+rename
prevents torn reads. DNS recovery does not restart the VPN; after DNS/open-internet recovery, the existing
reconnect loop resumes naturally. Any explicit future restart request is consumed inside that loop, never
by a second reconnect process.

---

## 6. Probes

- **`inet_e2e_ok` (R-NET) — open internet by name.** Run the Apple and Google probes concurrently under
  one **8-second total deadline**. Apple captures the response body and requires `Success`; Google
  discards the body and requires HTTP 204. Succeed if either passes. Do not use `-o /dev/null` for the
  Apple body check and do not nest per-endpoint retry loops inside the 20-second watcher. The existing
  two-consecutive-tick fault threshold provides anti-flap behavior. This is the authoritative internet
  signal; `inet_ip_ok` remains diagnostic.
- **`inet_ip_ok` — secondary.** Keep the existing ICMP/TCP-443-to-IP check so the status can distinguish
  "DNS dead, IP fine" (the incident signature) from "fully offline."
- **`dns_ok`** — unchanged (`host` through the OS resolver, 3 retries).
- **`crd_ok` (R-CRD) + `crd_required` (per-node).**
  - `crd_required` defaults from **installation presence** (the CRD host bundle/launchd definition),
    never process presence, with an explicit per-node override. If not required, `crd_ok=null` (N/A).
    If required and the process is absent, `crd_ok=false`, reason `host-down`.
  - When required, `crd_ok` = host process present (`pgrep -f remoting_me2me_host`) **and** the
    signaling endpoint reachable by name. Reachability = **any HTTP status returned** from
    `curl -sS -o /dev/null -m 6 -w '%{http_code}' https://remotedesktop-pa.googleapis.com` (a 4xx proves
    DNS+TLS+HTTP worked, so do **not** use `curl -f`); treat only `000`/timeout as unreachable.
  - **Known blind spot (stated, not hidden):** process-present + endpoint-reachable does **not** prove
    the host is *registered/online* with Google ("host-unregistered"). Detecting that needs the CRD host
    log/heartbeat; that is a future enhancement. `crd_ok` therefore means "reachable + host running," and
    `crd_reason` carries `host-down` / `signaling-unreachable` / `ok` (never claims registration).

Separately, `services_ok` and the `pf_*` fields feed the **Protection** signal (server_monitor), not the
connectivity verdict (carried over from the prior plan's "do not overload verdict" decision).

---

## 7. Verdict state machine (complete decision table)

Inputs: `desired` (on/off, from `vpn-desired`), `captive_hold` (reconnect's self-clearing hold),
`vpn_state` (`Connected` / `Connecting`|`Reconnecting` / `Disconnected` / wedged-unknown), `dns_ok`,
`inet_e2e_ok`, `inet_ip_ok`, `crd_ok` (or N/A), `crd_required`, `tailscale_ok`, `PROTECT_TS` (headless
flag), and `in_grace` (post-connect grace window). Evaluated **top to bottom, first match wins**; the
ordering encodes the §4 precedence (connectivity first, CRD next).

| # | Guard (first match wins) | Verdict | Action |
|---|---|---|---|
| 1 | `captive_hold == yes` | `CAPTIVE` | none; VPN stays down; reconnect auto-arms when captive probe clears |
| 2 | `vpn_state in {Connected, Connecting, Reconnecting}` and `in_grace` | `PENDING` | probe only; no recovery during grace |
| 3 | `vpn_state==Connected` and not `in_grace` and (`dns_ok==false` or `inet_e2e_ok==false` or (`PROTECT_TS` and `tailscale_ok==false`)) | `NO-GO` (`vpn-path`) | **AUTO-DISCONNECT VPN**, then classify the remaining fault next tick |
| 4 | `dns_ok == false` | `NO-GO` (`dns`) | run DNS-dead ladder (breaker `dns_dead`) |
| 5 | `dns_ok == true` and `inet_e2e_ok == false` | `NO-GO` (`internet`) | upstream/ISP outage: no self-fix loop; one alert |
| 6 | `crd_required` and `crd_ok == false` and `dns_ok` and `inet_e2e_ok` | `NO-GO` (`crd`) | run CRD-wedged ladder (breaker `crd_wedged`) |
| 7 | `tailscale_ok == false` and `PROTECT_TS` | `NO-GO` (`tailscale`) | no autonomous restart; one alert |
| 8 | `tailscale_ok == false` and not `PROTECT_TS` | `DEGRADED` | none |
| 9 | `desired == off` and connectivity probes healthy | `OFF` | none |
| 10 | `vpn_state==Connected` and required probes healthy | `GO` | none |
| 11 | `desired == on` and `vpn_state in {Disconnected, Connecting, Reconnecting, wedged-unknown}` | `NO-GO` (`vpn-down`) | reconnect loop owns recovery, captive-gated |
| 12 | default | `NO-GO` (`unknown`) | log; no privileged action |

Rows are executable as written: no row refers to a later row. Row 3 is the only safety disconnect and
is post-grace. After disconnect, row 4 distinguishes resolver poisoning from a tunnel-path failure.
Rows 4 and 6 may act regardless of desired state because reachability outranks VPN posture. `OFF` and
`CAPTIVE` are intentional states and raise no alert.

---

## 8. Recovery ladders

Recovery is **interleaved with the normal probe loop**: at most one ladder action per tick for a given
fault, then normal probing continues and re-probes the result on the next tick. This keeps status fresh
(no "slow loop") and naturally spaces rungs. The breaker (§9) gates how many times the ladder may run.

**DNS-dead ladder** (fixes §2.1/§2.2; the `tailscaled` rung from v1 is removed):

| Rung | Action | By | Notes |
|---|---|---|---|
| detect | `dns_ok=false` for >=2 ticks | healthcheck | unchanged threshold |
| 1 | `dns-flush` | root helper | cheap cache/reset action |
| 2 | watcher disables MagicDNS, inventories system nameservers, directly probes suspicious VPN-range resolvers and DHCP nameservers; if DHCP DNS works but system DNS does not, call `dns-override` | watcher + root helper | ownership-neutral fix for the observed foreign VPN resolver poison |
| top | re-probe after the DNS override; if still dead, complete the bounded cycle | healthcheck | no VPN restart from a DNS fault; once DNS works, the existing reconnect loop observes open internet and owns VPN recovery |
| open | breaker opens: stop DNS recovery actions, keep probing, one coalesced alert | healthcheck | see §9 |

`dns-override` discovers the active service from the default-route interface, reads DHCP DNS from that
interface, records the exact prior service DNS mode/values in a root-owned rollback journal, and
promotes the DHCP servers as explicit service DNS. If DHCP DNS is unavailable, it refuses rather than
guessing. On network/service change, or once the suspicious resolver disappears and normal DHCP DNS is
healthy, the watcher calls `dns-restore` before doing anything else. A static public fallback is an
explicit emergency command only, never autonomous.

**CRD-wedged ladder** (only when row 4 fires: internet healthy but CRD not):

| Rung | Action | By | Notes |
|---|---|---|---|
| detect | `crd_ok=false` while internet+dns healthy, >=2 ticks | healthcheck | |
| 1 | `restart-crd` (kickstart the privileged CRD LaunchDaemon) | **root helper** | restarts the host process |
| open | breaker opens: one alert (cannot fix host-unregistered beyond restart) | healthcheck | |

Every privileged rung re-verifies the out-of-band lifeline (Tailscale SSH + CRD) immediately after; if a
rung worsens the lifeline, it is reverted and the breaker opens rather than continuing.

---

## 9. Circuit breaker / flap detector (R-BREAK)

**Single writer:** only the launchd `--watch` healthcheck owns breaker state. One-shot healthchecks are
probe-only. **Location:**
`~/.config/darkmesh/breakers.json` (user-owned; the root helper never touches it). Atomic temp+rename on
every update.

**Per-fault map** (`dns_dead`, `crd_wedged`, ...), so simultaneous faults are independent:
```json
{
  "schema": 1,
  "breakers": {
    "dns_dead": {
      "state": "closed",          // closed | open | half_open
      "ladder_rung": 0,           // current rung within the active cycle
      "cycles": [ {"started_at": "...", "ended_at": "...", "result": "recovered|failed"} ],
      "recover_refail_count": 0,  // flap counter within the window
      "opened_at": null, "alerted_at": null, "gave_up": false,
      "last_action": {"rung": 2, "verb": "accept-dns=false", "at": "...", "result": "still_dead"}
    }
  }
}
```

**Budget that always traverses the ladder (fixes the v1 "4 total, 2/rung" exhaustion):**
- A **cycle** = one full pass through the fault's ladder: rung 1 → re-probe → rung 2 → re-probe → ... →
  top rung → re-probe. **One attempt per rung per cycle** (no per-rung repeats), interleaved one action
  per tick.
- **`MAX_CYCLES = 2` per rolling window `W = 30 min`.** If two full cycles fail within `W`, the breaker
  **opens** for that fault.
- **Open** = suppress *recovery actions* for that fault only; **keep probing and writing status at the
  normal cadence** (so server_monitor stays fresh and other faults are still detected and recovered);
  set `gave_up=true` with the probe vector + `last_action`; emit **one** coalesced alert (§12).
- **Half-open** after `cooldown C = 20 min`: allow one fresh cycle; recovered → close and reset; failed →
  re-open without re-alerting.
- **Anti-flap:** if a fault recovers then re-fails more than `F = 5` times within `W`, open it (flapping
  is a fault to surface, not to chase). The every-few-minutes VPN re-pin seen in `reconnect.log` is an
  example worth surfacing.
- **Persistence:** because state is on disk and read at the top of every tick, a `launchctl` restart or
  reboot **resumes** the budget instead of resetting it (fixes §2.3 and satisfies the "loops must
  terminate" rule).

The reconnect loop independently persists its failure window, app-restart count, give-up state, and
half-open cooldown in `~/.config/darkmesh/reconnect-state`; restarting launchd or rebooting cannot reset
that budget.

Thresholds (`W`, `MAX_CYCLES`, `C`, `F`) are config, not hardcoded.

---

## 10. Privileged root helper + scoped indefinite sudo (R-SUDO)

**Model (extend the existing one):** `install-dns-recover-helper.sh` already installs a **root-owned,
root-only-writable** helper at `/Library/darkmesh/bin/` plus a sudoers drop-in granting `NOPASSWD` for a
single absolute path. The user cannot edit what runs as root, so this is not a general escalation.
Generalize it to a **minimal fixed verb set** (kept deliberately small per the review):

| Verb | Action | Why root |
|---|---|---|
| `dns-flush` | `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | mDNSResponder reset needs root |
| `dns-override` | discover active service; snapshot prior DNS; promote current DHCP DNS | service DNS mutation |
| `dns-restore` | atomically restore the snapshotted service DNS and remove journal | service DNS mutation |
| `restart-crd` | kickstart the install-time-verified CRD launchd label/domain | privileged job control |

The helper never infers which VPN owns a resolver. The watcher makes the policy decision from probe
evidence. The helper's only state is a bounded root-owned rollback journal containing service name and
prior DNS values. No `tailscaled` restart, breaker writes, diagnostics snapshot, or free-form resolver
arguments. The installer discovers and validates the actual CRD launchd domain/label; if it cannot,
`restart-crd` is not installed or authorized.

**Hardening (the helper is the trust boundary):** verb matched against a literal `case` allowlist;
anything else exits non-zero; no free-form arguments; never passes input to a shell; logs verb + caller
uid to `/var/log/darkmesh-root-helper.log`.

**Sudoers (defense in depth, enumerate exact verbs):**
```
# /etc/sudoers.d/darkmesh-root-helper   (mode 0440, validated with visudo -cf)
Cmnd_Alias DARKMESH_RECOVER = /Library/darkmesh/bin/darkmesh-root-helper dns-flush, \
                              /Library/darkmesh/bin/darkmesh-root-helper dns-override, \
                              /Library/darkmesh/bin/darkmesh-root-helper dns-restore, \
                              /Library/darkmesh/bin/darkmesh-root-helper restart-crd
<user> ALL=(root) NOPASSWD: DARKMESH_RECOVER
```

**Why this is "indefinite sudo done right":** `NOPASSWD` never expires (the indefinite part), but it is
bounded to a closed fixed-verb set, not a root shell. **Never `NOPASSWD: ALL`.** Granting it is a one-time
admin-authenticated install per machine.

**server_monitor is empowered without root:** per the runbook invariant it must never own network policy
or hold sudo. It is empowered by (a) the richer read-only status (§12) and (b) the **existing generic
Protection Repair path**, whose repair command shells a documented **user-level** darkmesh entrypoint
that escalates through the helper. No new privilege, no new button, no real tool names in tracked source.

---

## 11. Logging redesign (R-LOG)

- **Rotation:** ship `/etc/newsyslog.d/darkmesh.conf` rotating each darkmesh log at ~5 MB, keep 5
  compressed, correct owner per file (user logs vs the root helper log). Installed by the privileged
  installer; no daemon.
- **Stop the duplicated launchd stderr copy.** `darkmesh-healthcheck:49` `log()` does
  `tee -a "$LOG" >&2`, and launchd captures stderr to its own (unrotated) file. In `--watch` mode write
  **only** to the rotated file (no `>&2`), and point the LaunchAgent plist `StandardOutPath` and
  `StandardErrorPath` to **`/dev/null`**. Do not point launchd at the application log: launchd keeps an
  open descriptor across `newsyslog` rotation. Keep stderr only for one-shot/interactive mode.
- **De-spam:** in `--watch`, log at most one line per **transition or action**, not per tick; summarize
  steady-state GO (one heartbeat line per N minutes, or only on change). Collapses the 12 MB to
  kilobytes/day.
- **Append-only action log:** `~/Library/Logs/darkmesh/actions.log` (+ the root
  `/var/log/darkmesh-root-helper.log`) records every recovery action and breaker transition as one
  structured line: `ts fault rung verb result breaker_state`. This is the postmortem record missing
  today.
- **Fleet visibility (phase 2):** `darkmesh-audit --json` per node + the last few `actions.log` lines,
  collected by the fleet tool (§13), give a one-screen "what has each node done" view without shipping
  logs off-box.

---

## 12. server_monitor integration (status schema 3, euphemized, no sudo, reuse Repair)

- **Bump `/tmp/darkmesh-status.json` to `schema: 3`, additive only** (contract: add keys, never rename;
  consumers tolerate-or-warn). New keys: `inet_e2e_ok`, `inet_ip_ok`, `crd_ok` (nullable), `crd_required`,
  `crd_reason`, and a **`breakers` map** keyed by fault (`{ state, gave_up, opened_at, last_action }`
  per fault), so concurrent DNS + CRD faults are both representable.
- **Decode** in `Models/DarkmeshStatus.swift` as optional fields (old nodes still decode).
- **UI: reuse the existing generic Protection path** (`DarkmeshStatusView.swift:127-138` already renders
  an AT RISK badge + one-click `protection.repair()` for repairable failures). Add darkmesh recovery as
  a **repairable check in the untracked `protection.json`** (its repair command = the documented
  user-level darkmesh entrypoint). Add read-only status rows for Open-internet and CRD next to
  Internet/DNS/Tailscale, and surface `breakers[*].gave_up` as a distinct "recovery gave up" AT RISK
  reason. **No new button.**
- **Alert (DECIDED 2026-06-22):** one **coalesced** local notification (a "since you last looked"
  digest, replace-not-stack, never one per event) + the server_monitor red state. A **push** channel for
  stuck headless nodes is **roadmapped**, out of scope this round.
- **Public hygiene:** all new fields generic; real labels stay in untracked `protection.json`.

---

## 13. Fleet rollout (R-FLEET)

- **Inventory = an untracked allowlist**, not `tailscale status` autodiscovery (autodiscovery is not a
  safe fleet inventory and would sweep nodes that should not be touched). E.g. `~/.config/darkmesh/
  fleet-nodes` (or the CHOAM-synced config), one ssh target per line.
- **Privileged install is admin-gated, not unattended.** Passwordless root cannot be bootstrapped without
  existing authorization on the target, so `install-root-helper.sh` (helper + enumerated sudoers +
  `newsyslog`) runs with an interactive admin auth (or a pre-authorized admin channel) **per node**. The
  fleet tool performs the **user-level** arm automatically (copy scripts, load user agents, run
  `darkmesh-audit`) and **reports which nodes still need the one-time admin install** rather than
  pretending it did it.
- **Canary:** roll to one node first, soak and verify (audit + observed recovery), then the rest.
- **Version/hash verification:** `darkmesh-audit` compares the deployed helper's `sha256` to the repo's
  expected hash and flags drift or tampering, and asserts the enumerated sudoers rule validates and the
  `newsyslog` drop-in is present.
- **`nice -n 19` on every remote command** (the standing constraint for the headless mini, so darkmesh
  work yields to the services it co-hosts).
- **Explicit results, no silent caps:** per-node `PASS` / `FAIL` / `SKIPPED` (offline / needs admin) is
  printed; "the fleet is healed" never overstates coverage.

---

## 14. File-by-file change list

**`darkmesh-vpn-guard`**
- `scripts/darkmesh-healthcheck` — add `inet_e2e_ok` / `inet_ip_ok` / `crd_ok`(+`crd_required`) probes;
  implement the §7 verdict table; move DNS recovery out of the `Disconnected`-only branch; own the
  breaker (§9) as single writer; perform the `accept-dns` decision itself and call the helper for
  `dns-flush`; interleave recovery one-action-per-tick; transition/action-only logging; stop the stderr
  tee in watch mode; write schema-3 status.
- `scripts/darkmesh-dns-recover` → `scripts/darkmesh-root-helper` — fixed verbs (`dns-flush`,
  `dns-override`, `dns-restore`, `restart-crd`); root-only; arg allowlist; rollback journal; logging.
  No DNS ownership/direction policy and no breaker writes.
- `scripts/darkmesh-breaker` *(new, sourced lib)* — read/evaluate/update breaker state (used only by the
  healthcheck).
- `scripts/install-dns-recover-helper.sh` → `scripts/install-root-helper.sh` — install the fixed-verb
  helper, the enumerated sudoers rule (validated), the `newsyslog` drop-in.
- `scripts/install-user-tools` — call `install-root-helper.sh` explicitly (auditable); pin healthcheck
  plist args; ensure reconnect agent + plist installed; set plist `Standard*Path` to `/dev/null`.
- `scripts/darkmesh-reconnect` — consume explicit wedge-restart requests inside the existing loop,
  captive/desired gate them, keep its own sidecar, and write to the shared action log. DNS recovery
  itself does not request a VPN restart.
- `scripts/darkmesh-audit` — assert helper version + sha256, sudoers validity, `newsyslog`
  present, breaker file present/writable by the healthcheck; `--json`.
- `scripts/darkmesh-fleet` *(new)* — allowlist-driven; user-level arm + `darkmesh-audit --json`;
  `nice -n 19`; canary flag; per-node PASS/FAIL/SKIPPED + needs-admin report.
- `newsyslog/darkmesh.conf` *(new)*; `vpn-guard/com.user.darkmesh-healthcheck.plist` (pin args +
  `Standard*Path`); `swiftbar/darkmesh.10s.sh` (render new probes + breakers until retirement); docs
  (`runbook.md`, dated `investigation-log.md` entry, `ROADMAP.md`, cross-link from
  `availability-recovery-plan.md`).

**`server_monitor`** (PUBLIC, lockstep)
- `Models/DarkmeshStatus.swift` — decode `inet_e2e_ok`, `crd_ok`(nullable), `crd_required`, `breakers`
  map (optional).
- Darkmesh panel — Open-internet + CRD rows; `breakers[*].gave_up` as an AT RISK reason via the existing
  Protection path; no new button.
- `~/.config/server-monitor/protection.json` *(untracked)* — add the darkmesh recovery check as a
  repairable entry. `config/protection.example.json` + `CONFIG.md` document the generic pattern.
- `ROADMAP.md` — lockstep pointer.

---

## 15. Test plan

**Phase 1 (deterministic, no risk): stubs + injectable clock.** Provide fake `expressvpnctl`,
`Tailscale`, `host`, `curl`, `scutil`, `pgrep`, and an injectable time source so breaker windows/cycles
are deterministic. Assert:
- DNS ladder reaches rung 2, disables MagicDNS, proves DHCP DNS works, performs an override, then restores
  the exact prior DNS configuration when the poison disappears or the active service changes.
- Breaker traverses the full ladder, runs exactly `MAX_CYCLES` before opening, opens only the affected
  fault, keeps probing, emits exactly one alert; restart mid-fault resumes the budget from disk; half-open
  after cooldown.
- Verdict table: each row 1-12 produces the specified verdict + action; CRD N/A path never NO-GOs a
  non-CRD node; `curl` 4xx counts CRD reachable.
- Logging: GO produces no per-tick spam; one structured `actions.log` line per action; no stderr dup.
- Reconnect consumes a request in its sole loop and preserves the app-restart cap across process restart.

**Phase 2 (one controlled canary, real, auto-rollback): no blackholing across headless nodes.** On a
single canary, exercise a real recovery with a **timed deadman auto-revert** (the pattern
`darkmesh-diag` already uses) so any misstep self-heals within a bounded window. Verify Tailscale SSH +
CRD survive every action. Roll to the rest only after a clean canary soak.

**Sudo/fleet:** every allowlisted verb succeeds passwordless under its safe preconditions; any unknown
verb is rejected by both sudoers and the helper; audit confirms helper sha256 + sudoers validity; fleet reports
PASS/FAIL/SKIPPED honestly with `nice -n 19`.

---

## 16. Risks & rollback

- **Rung 3 (ExpressVPN restart) could disturb the lifeline.** Re-verify Tailscale + CRD after; revert and
  open the breaker if worse. Behind the breaker, so rare and bounded.
- **Schema bump:** additive only; tolerate-or-warn (the contract that has held).
- **Sudoers change:** always `visudo -cf`; keep the old `darkmesh-dns-recover` rule until the new helper
  helper is verified on the canary, then remove it in the same change.
- **Rollback:** each piece is independently revertible (restore prior helper + sudoers, remove the
  `newsyslog` drop-in, revert the healthcheck). The breaker file is inert if unread.
- **No reboot rung** until Appendix B is satisfied.

---

## 17. Locked defaults and deferred items

Decided 2026-06-22 (recorded): escalation ceiling = service restarts + DNS changes, **no reboot** until
Appendix B; alerting = one coalesced local notification + server_monitor red, push roadmapped.

Locked for implementation:
1. Breaker defaults are locked for canary: `W=30m`, `MAX_CYCLES=2`, `C=20m`, `F=5`; configurable.
2. `crd_required` defaults from installation presence with explicit per-node override; locked.
3. Internet endpoints are Apple body-success OR Google 204 under one 8-second deadline; locked.
4. **Interface-name-only transfer-client binding** and **vpn-guard credential capture** remain open from
   the prior plan; not blockers this round.

---

## 18. Appendix A — exact artifacts

**Sudoers** `/etc/sudoers.d/darkmesh-root-helper` (0440, `visudo -cf` validated):
```
Cmnd_Alias DARKMESH_RECOVER = /Library/darkmesh/bin/darkmesh-root-helper dns-flush, \
                              /Library/darkmesh/bin/darkmesh-root-helper dns-override, \
                              /Library/darkmesh/bin/darkmesh-root-helper dns-restore, \
                              /Library/darkmesh/bin/darkmesh-root-helper restart-crd
<user> ALL=(root) NOPASSWD: DARKMESH_RECOVER
```

**Helper contract** (`/Library/darkmesh/bin/darkmesh-root-helper`, root:wheel 0755, dir not
user-writable): fixed literal verb allowlist; refuses any other token; no free-form args; never pipes
input to a shell; logs verb + `SUDO_UID`; DNS override is paired with an exact restore journal.

**`newsyslog`** `/etc/newsyslog.d/darkmesh.conf`: rotate each darkmesh log at ~5 MB, keep 5 compressed,
correct owner per file.

**Probe endpoints:** internet = `http://captive.apple.com/hotspot-detect.html` (body `Success`) and/or
`https://www.gstatic.com/generate_204` (204); CRD = `remotedesktop-pa.googleapis.com:443` (any HTTP
status = reachable) + `pgrep remoting_me2me_host`.

---

## 19. Appendix B — Headless-reboot prerequisite: auto-login (gates the reboot rung)

**Why this gates the reboot rung:** after a reboot the headless mini stops at the macOS **loginwindow**,
and Chrome Remote Desktop cannot inject keystrokes there (its host attaches to an active user session; it
can type into a locked session but not the pre-session login window). A remote reboot today strands the
box until someone is physically present, so darkmesh must never reboot until this is solved.

**State found 2026-06-22 (the affected mini):** macOS 15.2; **FileVault OFF**; **automatic login NOT
configured** (no `autoLoginUser`, no `/etc/kcpassword`); CRD host healthy and attached to the live
console session. Because FileVault is off, the fix is plain **automatic login** (no `fdesetup
authrestart` or stored FileVault key needed).

**Fix:** enable automatic login so a reboot lands directly in the desktop session (no loginwindow; CRD
attaches immediately):
- GUI (safest; no plaintext password in shell history; can be done from the current CRD session):
  System Settings → Users & Groups → *Automatically log in as* → the operator account.
- CLI alternative (needs sudo; password appears in argv):
  `sudo sysadminctl -autologin set -userName <user> -password '<pw>'`, then verify
  `sysadminctl -autologin status`.
- Screen-lock-after-sleep may stay on: a locked *session* is fine (CRD can type the unlock password
  within the session); the loginwindow is the only screen CRD cannot drive.

**Verification before enabling the reboot rung:** one controlled, unattended test reboot must return to a
CRD-reachable desktop with the darkmesh agents loaded+running (`darkmesh-audit` all-PASS). A failed
auto-login degrades only to today's behavior (reachable but un-typeable at the loginwindow), not worse, so
incremental risk is low; still schedule it when physical access is possible as a backstop. If FileVault is
ever enabled, switch the reboot rung to `fdesetup authrestart` (unlocks the boot volume for one reboot
without the pre-boot screen) instead of a plain reboot.

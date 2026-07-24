# Availability & Auto-Recovery Plan — darkmesh-vpn-guard  *(FINAL)*

> **Network ordering superseded 2026-07-15:** the global-probe-only captive gate,
> interruptible retry waits, and ExpressVPN autoconnect guidance in this historical
> plan are replaced by
> [`network-resilience-state-machine.md`](./network-resilience-state-machine.md).
> The priority hierarchy and transfer-client containment rules below still apply.

> **Background registration superseded 2026-07-13:** references in this historical
> plan to separate per-script LaunchAgents and Server Monitor one-click Repair are
> no longer operational guidance. One signed Server Monitor infrastructure agent
> supervises/schedules the stack; its polling panels are read-only. The safety
> invariants and recovery ladders in this document still apply.

> **DNS recovery superseded 2026-06-22:** the deployed helper's ownership
> assumption was disproved by a foreign VPN resolver recurrence. The corrected
> state machine, fixed root helper, duplicate-watcher lock, and persistent
> circuit breakers are specified in
> [`self-healing-hardening-plan-2026-06-22.md`](./self-healing-hardening-plan-2026-06-22.md).
> This document remains the source for the original availability architecture
> and invariants, not the current DNS ladder.

> **Status:** FINAL — synthesized from two independent agent plans + a synthesis review.
> **Date:** 2026-06-16.
> **Primary objective (this round):** fix the **infrastructure** — darkmesh + networking
> config — so the VPN self-heals and a broken/missing watchdog is *visible*. Completing any
> particular serve is **downstream** of this and partly manual (see Appendix A).
> **Repos:** `darkmesh-vpn-guard` (this repo) + `~/ios_code/server_monitor`.
> **Public-repo hygiene:** the transfer app is only ever "the transfer client" (see
> `transfer-vpn-doctor`'s runtime name decoding); ExpressVPN/Tailscale are named (the project
> is about their coexistence); no host names, tunnel IPs, content names, or app bundle ids.

> **Changelog vs the v1 proposal (what the review changed):**
> - Privacy posture **locked to Option 1** (VPN-locked + robust rebind); "Any" is an explicit
>   emergency override only (§4).
> - P0 `darkmesh-dns-recover` corrected: it's a **privileged** helper at `/Library/darkmesh/bin`
>   installed via `install-dns-recover-helper.sh` + sudoers — **not** `$BIN_DIR` (§6).
> - P2 rebind flow fixed: `--fix --quit` does **not** relaunch, and vpn-guard resume **no-ops
>   if the client isn't running** — so we must relaunch before resume (§8).
> - Protection "binding current" check fixed: the doctor **exits 0 even on STALE-BINDING** in
>   diagnostic mode → add a `--check` mode with real exit codes (§9).
> - Agent liveness: `launchctl print` only proves *loaded* → require **loaded + running +
>   fresh** for the loop agents; loaded-only for vpn-guard (§9).
> - **One status writer**: reconnect writes a **sidecar**; healthcheck merges (§10).
> - **README Network Lock** text reconciled to relaxed-mode reality (§6, §11).
> - Added **Fault B** (transfer client lacks removable-volume / Full Disk Access) as a
>   **manual operational prerequisite**, explicitly *out* of watchdog scope (Appendix A).
> - **Docs are not authoritative for intent.** Per the operator, README/docs may have drifted
>   from intentions. Ground every decision in **runtime + code + confirmed
>   operator intent**; "reconcile docs" means making docs match *confirmed intent*, not current
>   behavior. Treat README claims (Network Lock, custom DNS, "always enabled") as suspect until
>   confirmed.
> - Added **Phase 5 — captive-portal / untrusted-network handling** (operator posture confirmed
>   2026-06-16: **always-on, captive-aware**) after a public-venue captive-wifi failure on a
>   member node.

---

## 0. TL;DR

darkmesh is **fail-closed** (no leak when the VPN is down) but **not self-healing**, and it
gives **no signal** when a keep-alive watchdog is missing. Two independent diagnoses + a
review converged on the same picture:

- **Fault A (verified, both directions):** the transfer client is pinned to an **ephemeral
  ExpressVPN tunnel IP**. When that IP rotates/drops, the client can't bind — and as a
  *side effect* libtransfer never finishes session init, so the **disk hash-checker silently
  dies** (transfers stuck at `checkingDL 0%`). Proof: two restarts with the pin intact → dead;
  clear the pin → an internal-disk self-test instantly serves; restore the pin → dead again.
- **Fault B (high confidence, isolation-verified, manual fix):** the transfer client lacks
  macOS **removable-volume / Full Disk Access**, so it cannot read the external (USB) volume
  even when Fault A is fixed (internal-disk self-test serves; the external self-test is never
  `open()`ed). This is a **TCC GUI grant**, not a darkmesh concern.
- **Infra gaps that made A an outage instead of a blip:** the reconnect watchdog (which
  already has exponential backoff) **was never deployed**; it can't un-wedge a hung ExpressVPN
  client; nothing auto-rebinds after IP rotation; `darkmesh-panic` would fight it; and nothing
  surfaced the missing watchdog.

This plan fixes the **infrastructure** (Fault A + the deployment/observability gaps) in five
phases, all in this repo + `server_monitor`. **Fault B is Appendix A** — a manual runbook
prerequisite for actually serving, not part of the watchdog.

---

## 1. Invariants & priority hierarchy (governing law)

When anything conflicts, the higher number wins. This governs every phase below.

1. **Internet connectivity is paramount.** darkmesh must **never** self-inflict a block that
   stops the machine reaching a captive portal or the real internet. If a guard could block
   connectivity, the guard yields. A hardcoded resolver that breaks portal sign-in violates this.
2. **Chrome Remote Desktop is always reachable.** Secondary only to raw connectivity. Never
   blocked by any guard, on any network, in any state.
3. **The transfer client never leaks unprotected.** Primary guarantee is the client's
   socket-binding to the VPN tunnel; PF is the belt-and-suspenders. PF blocks *only* the
   transfer ports (`56378`, `6881–6889`, `6969`), nothing else; general traffic / browser / CRD
   are never touched. Keep it process/port-scoped; never a blanket kill-switch.
   **Fixed 2026-06-16:** the rules were correctly scoped but loaded into a top-level
   `vpn-guard` anchor the main ruleset never referenced (loaded-but-dead). Now nested under
   `com.apple/vpn-guard`, evaluated by the always-present `com.apple/*` wildcard — verified by
   probe (a blocked port drops *only* when nested). vpn-guard also ensures PF is enabled and
   publishes its state to the status file.
4. **Most traffic over VPN is a nice-to-have** — best-effort, never at the cost of #1 or #2.
5. **"Green" = Tailscale + VPN + services up — but it is a STATUS LIGHT ONLY.** Non-green must
   never enforce a connectivity block. The only thing darkmesh ever *enforces* is #3.

**Corollaries (hard):** Network Lock stays **OFF** (it can trap general internet on a tunnel
hiccup). DNS is **DHCP off-tunnel, never pinned**. Captive/untrusted handling drops **every**
guard except the transfer-client port block. ExpressVPN `autoconnect` is fine *as long as* it
never blocks #1/#2 (captive-aware hold, Phase 5).

## 2. Decisions locked

- **Privacy posture = Option 1** (review + both agents agree): keep the transfer client
  **VPN-locked**; make **rebinding robust**. Binding to **"Any"** defeats the darkmesh
  fail-closed invariant and is allowed **only** as an explicit, logged emergency override
  (a documented `transfer-vpn-doctor --emergency-any` or equivalent) — never the default,
  never automatic.
- **Two watchdogs, one status writer:** keep *safety* (`darkmesh-healthcheck`, revert) and
  *availability* (`darkmesh-reconnect`, connect) as **separate** loops; **centralize** status
  authorship so they don't clobber `/tmp/darkmesh-status.json`.
- **Verdict stays raw:** don't overload the VPN `verdict` with service-health. Add a separate
  `services_ok` for display; the menu-bar combined tint already merges VPN + Protection.
- **Network posture = always-on, captive-aware** (operator-confirmed 2026-06-16): VPN is the
  default on every network, **but** on a new/untrusted network darkmesh holds the tunnel down and
  uses **DHCP DNS** until real internet is confirmed, then auto-connects — so captive portals
  load and sign-in works. **Drop the hardcoded public DNS** (`8.8.8.8`/`64.6.64.6`, seen in
  `scutil --dns`); it broke a public-venue portal and is suspected documentation drift. See Phase 5.

---

## 2. Current architecture (as-built inventory)

| Component | Role | Deployed by | On the affected node? |
|---|---|---|---|
| `darkmesh-healthcheck` (`--watch`) | **safety**: auto-revert when up-but-unsafe; authors status JSON; calls privileged DNS recovery | `install-user-tools` (+ LaunchAgent) | ✅ (plist drifted — §6) |
| `darkmesh-reconnect` | **availability**: backoff reconnect when down & desired | **nothing** (installer gap) | ❌ |
| `vpn-guard` (`vpn-guard.sh` + PF) | **enforcement**: PF blocks transfer ports off-tunnel; pause/resume client via Web UI | `vpn-guard/vpn-guard-install.sh` (separate; needs sudo + client Web-UI creds) | ❌ |
| `transfer-vpn-doctor` | **rebind primitive** (`--fix`) | `install-user-tools` | present, never auto-run |
| `darkmesh-dns-recover` | privileged DNS-deadlock reset | `install-dns-recover-helper.sh` → `/Library/darkmesh/bin` + sudoers | helper install separate |
| `darkmesh-panic` | one-button reset to plain LAN | path | n/a (manual) |
| `server_monitor` Protection panel | surface invariants + one-click Repair; feeds menu-bar tint | the app | app present |

Only the **safety** layer ran on the affected node. Availability + enforcement were absent.

---

## 3. Root cause (evidence-grounded, `file:line`)

1. **Installer gap.** `scripts/install-user-tools:11-30` installs the healthcheck (+ agent)
   but never `darkmesh-reconnect`/its plist, never the dns-recover helper, never vpn-guard.
2. **Healthcheck is safety-only by design.** `scripts/darkmesh-healthcheck:286-330`:
   `Disconnected`+ok → `IDLE`, no action; the only action is AUTO-DISCONNECT (`:326`).
3. **Reconnect can't un-wedge.** `scripts/darkmesh-reconnect:37-57` only runs
   `expressvpnctl connect` (assumes it works); no app-restart escalation; backoff double-counts
   (`:52` + `:56`).
4. **No auto-rebind.** `transfer-vpn-doctor:210-218` detects `STALE-BINDING` but `--fix`
   (`:251-276`) is **manual**, **requires the client quit**, and sets `StartPaused=true`
   (`:276`) — and **does not relaunch** (`:251-259`).
5. **panic vs reconnect.** `scripts/darkmesh-panic:27-34` disconnects but never writes
   `vpn-desired=off`; reconnect's only stand-down is the healthcheck's `auto_disconnect_at`
   (`darkmesh-reconnect:25-33`) → they'd fight.
6. **Drift/portability.** `com.user.darkmesh-healthcheck.plist:8-12` is `--watch` only, but the
   field ran `--interval 900 --protect-tailscale` (hand-edited; 900 s = up to 15 min latency).
   `com.user.darkmesh-reconnect.plist:9` hardcodes the home path.
7. **dns-recover is privileged.** `darkmesh-healthcheck:208,214` calls
   `/Library/darkmesh/bin/darkmesh-dns-recover` via `sudo -n`; installed by
   `scripts/install-dns-recover-helper.sh` + a NOPASSWD sudoers rule — **not** `$BIN_DIR`.
8. **No "are the watchdogs running?" check.** Green meant "tunnel up now," so a missing agent
   was invisible.
9. **Doc drift.** `README.md:108-113` claims "Network Lock always enabled," but the project runs
   **relaxed** (Lock off; fail-closed via binding + PF + vpn-guard). Misleads operators *and*
   any check that keys off it. (Per the operator, the docs may have drifted and are not authoritative
   for intent — treat all such claims as suspect.)
10. **No captive-portal handling (verified on a member node, 2026-06-16).** DNS pinned to public
   servers (`8.8.8.8`/`64.6.64.6`, observed in `scutil --dns`) means macOS's captive probe can't
   load the portal (you can't reach `8.8.8.8` before sign-in, and the portal's DHCP-DNS redirect
   is bypassed); `autoconnect=true` tries to tunnel pre-sign-in; and `darkmesh-reconnect`
   (`desired=on`) reconnects the VPN every time the operator disconnects it to sign in. Net:
   portal won't load + the watchdog fights you → had to tether. Same "watchdog fights you" class
   as the headless incident.

---

## 4. Goals / Non-goals

**Goals:** G1 auto-recover when the VPN should be up (incl. restarting a wedged client);
G2 auto-rebind the client to the live tunnel after any (re)connect/IP-change, then relaunch +
resume; G3 one `vpn-desired` honored by all actors incl. panic; G4 "green" requires every
keep-alive service actually running, surfaced in `server_monitor` with one-click Repair;
G5 correct, drift-resistant deployment across all nodes.

**Non-goals:** never weaken fail-closed (N1); don't re-enable Network Lock here (N2, but *do*
fix the stale doc); never name the transfer client / hosts / IPs in tracked source (N3); no new
deps (N4); TCC/Full-Disk-Access is **out of scope** for the watchdog (Appendix A).

---

## 5. Watchdog responsibility matrix

Single source of truth for "should the tunnel be up": `~/.config/darkmesh/vpn-desired`
(`on`|`off`). Every actor reads it.

| Actor | Owns | Acts when |
|---|---|---|
| `darkmesh-healthcheck` | safety revert + **status JSON owner/merger** | up & unsafe → disconnect |
| `darkmesh-reconnect` | availability (connect + un-wedge) → writes a **status sidecar** | `desired=on` & down/wedged → recover |
| `vpn-guard` | PF enforcement + pause/**resume** (no-op if client not running) | unsafe/safe transitions |
| `transfer-vpn-doctor` | rebind primitive (`--fix`/`--check`/`--relaunch`) | invoked by reconnect post-connect |
| `darkmesh-panic` | intentional down | writes `vpn-desired=off` first |
| `server_monitor` Protection | observe agents + Repair; feeds tint | continuous |

---

## 6. Phase 0 — Deployment correctness *(highest ROI, lowest risk; pure infra)*

1. `scripts/install-user-tools`:
   - `install` `darkmesh-reconnect`; template + load `com.user.darkmesh-reconnect.plist`
     (substitute `__RECONNECT_BIN__`, matching the healthcheck pattern) via `bootout`/`bootstrap`.
   - **Run/Document the privileged DNS helper:** invoke `scripts/install-dns-recover-helper.sh`
     (installs to `/Library/darkmesh/bin` + NOPASSWD sudoers) — it needs an admin prompt, so make
     it explicit and auditable, not silent.
   - **Orchestrate vpn-guard** explicitly: call `vpn-guard/vpn-guard-install.sh`, surfacing that
     it needs **sudo** (PF) and the **client Web-UI credentials**. Provide a `--skip-vpn-guard`
     escape hatch; print exactly what it installed. (Review note: explicit + auditable, not best-effort.)
2. Pin the healthcheck plist to intended prod args: `--watch --protect-tailscale --interval <N>`
   (pick `N`≈20–30 s for headless; 900 s is far too slow). Fixes the drift in §3.6.
3. `com.user.darkmesh-reconnect.plist`: replace the hardcoded path with `__RECONNECT_BIN__`.
4. **Node audit** (`scripts/darkmesh-audit`, new): assert each required agent is loaded **and
   running and fresh** (see §9), each script/helper present (incl. `/Library/darkmesh/bin`),
   sudoers rule present; print one-line PASS/FAIL per node. Run on every machine; reconcile.
5. `README.md:108-113`: docs are **not authoritative for intent** and may have drifted. Confirm
   intent with the operator, then make **both** code and docs match it — here
   that means relaxed mode (Network Lock off; fail-closed via binding + PF + vpn-guard) +
   captive-aware DNS (Phase 5). Don't gate any check on Network Lock; correct the "always
   enabled" / custom-DNS text.

**Accept:** fresh install → all three agents loaded+running; `darkmesh-audit` all-PASS; plist
args match repo; DNS helper + sudoers present; README matches reality.

---

## 7. Phase 1 — Harden `darkmesh-reconnect` (wedge recovery + backoff)

1. **Wedge signal (review):** trigger app-restart when *"connect command accepted, but
   state/route/tunnel did not reach `Connected` within T across K attempts."* Treat a
   `--clear-cache` argv as **supporting evidence**, not the trigger.
2. **App restart (bounded):** `osascript quit` → `pkill -f 'MacOS/ExpressVPN'` (incl.
   `--clear-cache`) → `open -a ExpressVPN` → `expressvpnctl background enable` → resume ladder.
   Cap restarts/window (e.g. 3/h); alert on cap.
3. **Backoff hygiene:** single explicit wait; base 5 s → ×2 → cap 300 s → reset on `GO`; ±20 % jitter.
4. **Stuck-not-Disconnected:** also act on `Connecting`/`Reconnecting`/unknown beyond a threshold,
   not just exact `Disconnected` (`:39`).
5. **Lockout guardrail:** after each restart step, verify Tailscale (the ssh lifeline, split-tunnel
   bypassed) still resolves/pings; if it drops, stop + panic-revert + alert (CRD is the OOB fallback).
6. **Status sidecar:** write recovery fields to a sidecar (e.g. `/tmp/darkmesh-reconnect.json`);
   the healthcheck merges them (§10) — **don't** write `darkmesh-status.json` directly.

**Accept:** `expressvpnctl disconnect` → reconnect ≤ base backoff. Wedge sim → app restart +
reconnect, attempts capped, escalation logged, Tailscale never lost.

---

## 8. Phase 2 — Auto-rebind the transfer client after (re)connect

**Fix:** `--fix --quit` quits + edits but **does not relaunch**, and vpn-guard
`client_resume_all()` **returns early if the client isn't running** (`vpn-guard.sh:133-134`).
So the v1 "fix then resume" chain is broken.

1. Add `transfer-vpn-doctor --relaunch` (or have `darkmesh-reconnect` relaunch): after
   `--fix --quit` edits the config, **relaunch the client**, *then* delegate **resume** to
   vpn-guard (now that the process exists).
2. On a fresh `Connected` (or when the default-route utun IP changes), `darkmesh-reconnect`
   runs the rebind→relaunch→resume sequence as one idempotent function.
3. Prune the per-run config backups (`transfer-vpn-doctor:261-262`) so they don't accumulate
   one file per rotation.
4. Binding remains **interface + IP** to the live tunnel; evaluate interface-name-only as a
   later optimization (open Q, §13).

**Accept:** disconnect→reconnect (IP rotates) → client auto-rebinds, relaunches, resumes, and
serves **on the internal disk** within one cycle, no manual step. (External disk still needs
Appendix A.)

---

## 9. Phase 3 — Observability: "green ⊇ all keep-alive services running" *(operator request; in `server_monitor`)*

Maps onto `server_monitor`'s existing **Protection panel** (check/repair argv from untracked
`protection.json`; exit 0 = OK; one-click Repair; `combinedTint` already turns the dot yellow
on `protection.atRisk`). We add **checks**, not UI.

1. **Per-agent liveness (review item 4):** `launchctl print` only proves *loaded*. For the loop
   agents (`darkmesh-healthcheck`, `darkmesh-reconnect`) require **loaded + running + fresh**
   (status/sidecar mtime within a TTL). For **vpn-guard**, loaded is enough (event/interval).
   Repair = the bootstrap/install command for that agent.
2. **Binding-current check (review item 3):** the plain doctor **exits 0 even on STALE-BINDING**
   (`transfer-vpn-doctor:228`). Add a **`transfer-vpn-doctor --check`** mode with meaningful
   exit codes (0 = bound-current, 3 = stale, 4 = VPN down, …). Protection keys off that, not
   the diagnostic text. Repair = `transfer-vpn-doctor --fix --quit --relaunch`.
3. **Don't overload verdict (review):** keep the raw VPN `verdict` separate; add `services_ok`
   (+ `missing_agents[]`) for display/SwiftBar. If a combined signal is ever needed, introduce a
   distinct `effective_verdict` rather than mutating `verdict`. The menu-bar tint already merges
   VPN verdict + `protection.atRisk`.
4. Document the "service loaded+running" and "binding current" check patterns **generically** in
   `server_monitor/config/protection.example.json` + `CONFIG.md` (tracked); real labels/commands
   live in the untracked `protection.json`. Mirror a lockstep pointer in both `ROADMAP.md`s.

**Net:** if `darkmesh-reconnect` (or vpn-guard) isn't running — the exact incident condition —
the dot is non-green, Protection says AT RISK naming the agent, and Repair reloads it.

---

## 10. Phase 4 — Coordination, status, alerting

The health of the healthcheck is part of health. Process presence is insufficient:
the supervisor must observe tick progress, apply a whole-tick silence deadline,
and escalate to `SIGKILL` when graceful termination cannot interrupt a blocked
foreground command. Every consumer derives freshness from the authored timestamp
and file modification time using the schema-published maximum age.

1. **panic ↔ desired:** `darkmesh-panic` writes `vpn-desired=off` **first**; add `darkmesh-up`
   (sets `on` + kicks an attempt). Extend `darkmesh-reconnect` stand-down to honor `off` explicitly.
2. **One status writer (review item 5):** healthcheck owns `/tmp/darkmesh-status.json` and **merges**
   the reconnect sidecar; reconnect never writes the main file. Schema (additive, bump `schema`,
   tolerate-or-warn): `desired`, `recovery{active,attempt,backoff_s,app_restarts,gave_up,
   last_reconnect_at}`, `services_ok`, `missing_agents[]`. Coordinated decode in SwiftBar
   `darkmesh.10s.sh` + `server_monitor/Models/DarkmeshStatus.swift`.
3. **Give-up alert:** after a max window (~30 min) of failure → terminal NO-GO reason + a
   user-visible notification + slowed loop. Never thrash silently.
4. **Adaptive interval:** ~20–30 s while `GO`, ~10 s while recovering.

**Accept:** panic keeps VPN down (no fight); `darkmesh-up` restores; a permanent failure yields
exactly one alert; two loops never clobber the JSON.

---

## 11. Phase 5 — Captive-portal / untrusted-network handling *(posture: always-on, captive-aware)*

**Goal:** on a new/untrusted network (captive portal), let the operator get online *first*; then
auto-arm the VPN. Never let DNS overrides or the reconnect watchdog block or fight captive sign-in.

1. **DHCP DNS off-tunnel.** Stop pinning public DNS. When the VPN is DOWN (incl. captive hold), use
   the network's **DHCP-provided resolver** so the portal's redirect works; apply VPN/custom DNS
   only while the tunnel is UP. Find and remove the static `8.8.8.8`/`64.6.64.6` config wherever it
   lives (System Settings → Wi-Fi → DNS, and/or a darkmesh apply step). Treat the README "global
   nameservers + Override local DNS" step as AI-drift, not intent.
   **Build finding (2026-06-16): there is NO static DNS pin** — not in any darkmesh script,
   not on any network service; the public resolvers observed are the network's own DHCP DNS,
   so nothing to remove. ExpressVPN `autoconnect` is *startup-only*, not the captive cause.
   Implemented lever instead: the watchdog drops a stuck tunnel after 2 consecutive captive
   checks, plus `darkmesh-captive`.
2. **Captive gate before connect.** `darkmesh-reconnect` must not `connect` while a captive portal
   is unsatisfied. Gate on a probe: `http://captive.apple.com/hotspot-detect.html` → HTTP 200 with
   body `Success` = open internet (clear); redirect/non-200/timeout = captive or no internet (hold).
3. **New-network detection.** Track the active network identity (SSID / default-route gateway /
   router MAC) in the reconnect loop; on change → enter **captive-hold**: ensure VPN down, ensure
   DHCP DNS, watchdog stands down, begin probing. This composes with `vpn-desired`: captive-hold is
   an automatic, self-clearing `desired=off`.
4. **Auto-arm.** Once the probe reports open internet and is stable for a few seconds → connect the
   VPN, re-apply VPN DNS, and run the Phase-2 rebind→relaunch→resume for the transfer client.
5. **Manual override retained.** `darkmesh-panic`/`darkmesh-up` (Phase 4) remain the manual escape;
   optionally a thin `darkmesh-captive` alias = "hold until I'm online."
6. **Network Lock stays OFF** (relaxed) — Lock-on would block the portal outright; another reason
   the README "always enabled" line is wrong and must be corrected.

**Accept:** join a network whose captive probe returns non-`Success` → VPN stays down, DHCP DNS in
place, the portal loads and sign-in works, the watchdog does **not** fight; once online, the VPN
auto-connects within the probe window and the transfer client rebinds. Re-run the captive-portal scenario
(or a hotspot with a portal) end-to-end.

---

## 12. File-by-file change list

**`darkmesh-vpn-guard`**
- `scripts/install-user-tools` — install+load reconnect; run `install-dns-recover-helper.sh`; orchestrate vpn-guard (explicit sudo/creds, `--skip-vpn-guard`); pin healthcheck args.
- `vpn-guard/com.user.darkmesh-reconnect.plist` — `__RECONNECT_BIN__` template.
- `vpn-guard/com.user.darkmesh-healthcheck.plist` — pin `--protect-tailscale --interval <N>`.
- `scripts/darkmesh-reconnect` — wedge signal + bounded app-restart; backoff hygiene; stuck-state; lockout guard; rebind→relaunch→resume call; status **sidecar**; honor `desired=off`; **captive gate (probe before connect) + new-network detection** (Phase 5).
- **DNS / static resolver (Phase 5)** — remove the hardcoded public DNS (`8.8.8.8`/`64.6.64.6`); DHCP DNS off-tunnel, custom only on-tunnel. Locate wherever it's set (Wi-Fi service DNS and/or a darkmesh apply step).
- `scripts/darkmesh-captive` *(new, optional)* — manual "hold until online" alias (sets desired-off + DHCP DNS until the captive probe clears).
- `scripts/transfer-vpn-doctor` — add `--check` (exit codes) + `--relaunch`; prune backups; (optional) `--emergency-any` override.
- `scripts/darkmesh-panic` — write `vpn-desired=off` first.
- `scripts/darkmesh-up` *(new)* — set `on` + kick reconnect.
- `scripts/darkmesh-audit` *(new)* — loaded+running+fresh assertions per node.
- `swiftbar/darkmesh.10s.sh` — render new fields.
- `README.md` (Network Lock §), `ROADMAP.md`, `docs/runbook.md` (Appendix A + ops), `docs/investigation-log.md` (dated entry).

**`server_monitor`**
- `~/.config/server-monitor/protection.json` *(untracked)* — agent loaded+running+fresh checks; `transfer-vpn-doctor --check` binding check; Repairs.
- `config/protection.example.json`, `CONFIG.md` *(tracked, generic)* — document the patterns.
- `Models/DarkmeshStatus.swift` — decode new optional fields.
- `ROADMAP.md` — lockstep pointer.

---

## 13. Test plan (two consecutive clean runs each)

- **P0:** fresh install → 3 agents loaded+running; `darkmesh-audit` all-PASS; DNS helper+sudoers present; README matches relaxed reality.
- **P1:** disconnect → reconnect ≤ base backoff; wedge sim → app-restart+reconnect, capped, Tailscale never lost.
- **P2:** IP rotation → rebind+relaunch+resume → **internal** self-test serves, no manual step; backups pruned.
- **P3 (server_monitor):** `launchctl bootout` reconnect → dot non-green within a poll; Protection AT RISK names it; Repair reloads → green. Stale binding → `--check` non-zero → AT RISK → Repair fixes.
- **P4:** panic keeps VPN down ≥5 min; `darkmesh-up` restores; permanent-fail → one alert; JSON never clobbered.
- **P5 (captive):** join a network whose captive probe returns non-`Success` (a phone hotspot with a portal, or a venue) → VPN stays down, DHCP DNS present, portal loads, sign-in works, watchdog doesn't fight → once online, VPN auto-arms and the client rebinds. Re-run the captive-portal scenario.
- **Lockout safety:** ssh-over-Tailscale survives every VPN transition above.

---

## 14. Open questions for reviewer

Resolved by the review pass (recorded): wedge signal = §7.1; two watchdogs + centralized status =
§1/§10; vpn-guard ownership = explicit/auditable §6; verdict vs Protection = §1/§9.3; status
clobber = sidecar+merge §10.

Still open:
1. **Interface-name-only binding** — sufficient on the current client build to survive a
   same-utun IP refresh without quit/edit/relaunch? If yes, Phase 2 gets much cheaper.
2. **vpn-guard credentials at install** — how to capture the client Web-UI creds securely during
   `install-user-tools` (keychain entry?) rather than prompting interactively each node.
3. **Healthcheck interval** — single value vs adaptive; confirm 20–30 s is acceptable CPU on the
   headless node.

---

## Appendix A — Fault B: transfer client removable-volume / Full Disk Access *(manual prerequisite; NOT watchdog scope)*

Independent of darkmesh. Even with Fault A fixed, the transfer client cannot read the **external
(USB) volume**: other tools (the shell, node, rclone, the JVM transfer tool) hold macOS
removable-volume access, but the transfer client does **not** — so its checker opens internal-disk
files but never `open()`s files on the external volume (isolation-verified; `lsof` = 0).

**Fix (manual, GUI, by the operator — do not hand-edit `TCC.db`; a bad edit wipes the grants the
other tools rely on):**
1. On the node's screen (physically or via Chrome Remote Desktop):
   System Settings → Privacy & Security → **Full Disk Access** → **+** → add the transfer client
   app → toggle **on**.
2. Restart the transfer client; run an external-volume self-test → confirm it `open()`s and serves.

Document this in `docs/runbook.md` as a per-node prerequisite. Confidence: **high** (isolation +
TCC absence), to be re-confirmed once Fault A is stable. This gates *serving from the external
volume*; it does **not** gate the infrastructure work above.

---

## Appendix B — Completing the transfer (downstream, after infra + Appendix A)

Out of scope for "fix the infrastructure," recorded for continuity: once Fault A is robust and
Appendix A is granted, add the queued items (`savepath` = the external volume, forced recheck;
sequential recheck ~minutes → serving), then handle source-of-truth migration (stop duplicate
serves elsewhere only after confirming). The VPN is currently **up** on the node, so the
infra-side prerequisites for a later serve are partially in place.

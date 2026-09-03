# Roadmap — darkmesh-vpn-guard

> **Network posture update — 2026-08-04:** `darkmesh posture` now publishes a
> schema-2 desired/observed contract, eight explicit Tailscale/VPN priority
> profiles, passive topology, and bounded opt-in peer diagnostics for Server
> Monitor. Profile changes remain explicit, transactional, and recovery-owned;
> the strict zero-general-egress-leak profile remains capability-gated because
> Darkmesh does not claim a machine-wide kill switch.

> **Posture enforcement update:** a successful Apply records a separate
> enforced profile consumed by both long-running supervisors. Required
> Tailscale makes the optional commercial VPN yield after confirmed failures,
> repairs stopped intent without resetting identity, and gates VPN recovery
> behind an explicit rearm. Large Tailscale peer maps are parsed before
> display output is capped.

> **Background architecture update — 2026-07-13:** the per-script LaunchAgents
> described below are now a legacy fallback. Server Monitor bundles one Developer
> ID-signed `SMAppService` infrastructure agent that supervises the healthcheck and
> reconnect loops, wakes reconnect on native network-path changes, and schedules
> the packet-filter reconciler. `darkmesh setup` merges only its owned config IDs
> and `darkmesh-migrate-agent` retires the old registrations with rollback. Server
> Monitor's Protection panel is read-only; repairs remain explicit operator tools.

Status as of 2026-05-22. The active project goal is **retirement of the
SwiftBar plugin** once `server_monitor` reaches feature parity. SwiftBar is
a stopgap for menu-bar visibility; the native Swift app at
`~/ios_code/server_monitor` is the long-term home.

Paired roadmap (the *consumer* side): `~/ios_code/server_monitor/ROADMAP.md`.
Both should move in lockstep. **Do not delete the SwiftBar plugin until the
server_monitor roadmap signals Phase 6 is reached.**

Read this together with [CLAUDE.md](./CLAUDE.md) and
[docs/investigation-log.md](./docs/investigation-log.md). The investigation
log explains *why* darkmesh exists in its current form; this roadmap covers
*what's next*.

The active network-ordering contract is
[`docs/network-resilience-state-machine.md`](./docs/network-resilience-state-machine.md).
It supersedes the older global-probe-only captive gate and ExpressVPN autoconnect
guidance.

---

## Current state (post-commit `8ac47c3`)

What's running on the primary headless test host:

- **Working ExpressVPN + Tailscale + the transfer client stack**: protocol set to
  WireGuard, `tailscale set --accept-dns=false` auto-toggled by the
  healthcheck on connect/disconnect, the transfer client socket-bound to the VPN
  utun with leaked listen sockets fixed.
- **`darkmesh-healthcheck`**: signed-supervisor child polling every 20s, with schema-4
  end-to-end internet/CRD probes, a duplicate-instance lock, persistent
  per-fault circuit breakers, foreign-resolver DHCP recovery, a bounded Tailscale
  probe, and a 90-second whole-tick progress watchdog. Code complete;
  privileged canary + fleet rollout pending.
- **SwiftBar plugin**: `swiftbar/darkmesh.10s.sh` rendering verdict +
  probes + actions in the menu bar.

The SwiftBar plugin is feature-complete enough that the user is
unblocked — but it's a runtime dependency on a third-party menu-bar runner.
That's why it's slated for retirement.

---

## The retirement plan

This is the *darkmesh-vpn-guard side* of the work. The bulk of the work
is in the server_monitor repo; here we just keep the SwiftBar plugin
maintained until that work lands, then we delete it cleanly.

### While server_monitor is still being built

- **Keep SwiftBar plugin maintained.** If any of the underlying CLI tool
  paths change (`expressvpnctl`, `darkmesh-healthcheck`,
  `emergency-restore-internet`), update both the plugin and the
  server_monitor roadmap so they don't drift.
- **Don't add features only to the plugin.** Any new menu-bar capability
  must land in `server_monitor/ROADMAP.md` first; if it makes sense in
  the plugin too, mirror it there as a stopgap. The plugin is *not* a
  place to innovate UX.
- **Keep the JSON schema stable.** `darkmesh-healthcheck` writes
  `/tmp/darkmesh-status.json` with the schema both consumers depend on.
  Schema changes require coordinated updates to the plugin and to
  `server_monitor`'s `Models/DarkmeshStatus.swift`. Bump a `schema`
  field and consumers should tolerate-or-warn on mismatch.

### Cannibalise checklist — port these SwiftBar actions into server_monitor first

The SwiftBar plugin (`swiftbar/darkmesh.10s.sh`) is today the *only* place some
controls live. Before deleting it, confirm `server_monitor`'s darkmesh panel covers
each — port any that are missing (this is the "cannibalise" step the operator asked
for):

- [x] Status row: verdict + raw IP / open internet / DNS / Tailscale / optional
      remote-access health, temporary DNS override, and breaker state.
- [ ] **Disconnect VPN** action.
- [ ] **Run healthcheck now** (one-shot `darkmesh-healthcheck --no-revert`).
- [ ] **Emergency restore internet** (`emergency-restore-internet`).
- [ ] **Open ExpressVPN** / **Open Tailscale**.
- [ ] **Reveal status JSON in Finder**.
- [ ] Travel controls: `darkmesh-captive` / `darkmesh-up` (re-arm).
- [ ] Surface the remaining schema-4 `desired`, `services_ok`, and reconnect details.

`server_monitor`'s darkmesh and Protection panels are intentionally read-only;
the signed supervisor owns scheduled policy reconciliation and explicit operator
tools own manual actions. Mirror the consumer side in `~/ios_code/server_monitor/ROADMAP.md`
(lockstep). Only after parity is confirmed on two runs do the deletion below.

### When server_monitor signals Phase 6 is reached

The server_monitor ROADMAP's Phase 5 test plan must pass on **two
consecutive runs** before any deletion here. Verification: the user has
`/Applications/ServerMonitor.app` running, its menu-bar dropdown shows
darkmesh status with working Connect/Disconnect/Probe/Restore/Open
buttons, and the auto-revert backstop has been observed working through
the native app's view.

Once that's true, do this in one commit:

1. Delete `swiftbar/darkmesh.10s.sh` from this repo. Keep the file in git
   history; no archive needed.
2. Remove the SwiftBar install block from `scripts/install-user-tools`
   (the `if [[ -d /Applications/SwiftBar.app ]]` block).
3. Remove the SwiftBar section from `README.md` and replace with a
   pointer to `~/ios_code/server_monitor`'s install/build instructions.
4. Update `docs/server-monitor-integration.md` to remove the "No-Xcode
   fallback: SwiftBar plugin" section, since the fallback is no longer
   the recommendation.
5. Append a dated entry to `docs/investigation-log.md`:

   ```markdown
   ## YYYY-MM-DD — SwiftBar retired

   Native server_monitor menu-bar widget reached parity (see
   server_monitor ROADMAP.md Phase 5). Plugin and install hook removed.
   ```

6. Commit message: `Retire SwiftBar plugin; native server_monitor is GA`.
7. On the user's machine, run the cleanup commands documented in
   `server_monitor/ROADMAP.md` Phase 6 (uninstall SwiftBar, remove the
   plugin file from `~/Library/Application Support/SwiftBar/plugins/`,
   `defaults delete com.ameba.SwiftBar PluginDirectory`).

---

## Standing work outside this thread

These are not blockers for SwiftBar retirement but should be addressed
when convenient. Future sessions can pick any of these up.

- **PF kill-switch wired — RESOLVED 2026-06-16 (code; deploy pending).** Diagnosis
  confirmed by probe on the M5: `vpn-guard` loaded block rules into a *top-level*
  `vpn-guard` anchor the main ruleset never referenced (stock `/etc/pf.conf` only
  references `com.apple/*`; ExpressVPN inserts `com.express.vpn/*` dynamically via the
  private API) — so the rules were loaded-but-dead. Fix: nest the rules under
  **`com.apple/vpn-guard`**, which the always-present `com.apple/*` wildcard evaluates —
  no main-ruleset reload, no ExpressVPN clobber, no root daemon. `vpn-guard.sh` now also
  ensures PF is enabled (`pfctl -E` if disabled) and publishes `pf_*` to the status file.
  Verified by probe: a blocked port drops *only* when nested here. Socket-binding stays the
  primary guarantee; this restores the packet-level backstop. **Deploy still pending** (per
  node: updated `vpn-guard.sh` + sudoers via `vpn-guard-install.sh`, then `darkmesh-audit`).

- **ExpressVPN minimum-version check (deferred 2026-06-16).** darkmesh should confirm
  the installed ExpressVPN meets a floor — old clients carry the split-tunnel race +
  DNS bugs (remote-node was found running a stale, logged-out, out-of-date client). Prototyped
  then deferred: in `darkmesh-audit`, read `defaults read
  /Applications/ExpressVPN.app/Contents/Info.plist CFBundleShortVersionString`, compare
  to `MIN_EXPRESSVPN` (≈14.0.0) with `sort -V`; **advisory FAIL only** — surface it, never
  block the VPN (connectivity is paramount, §1). Optionally publish `expressvpn_version`
  to the status file so `server_monitor` can show it.

- **`--protect-tailscale` per-host: RESOLVED 2026-06-24; hardened 2026-09-03.** The
  healthcheck plist template no longer hardcodes the flag; it carries a
  `__PROTECT_TS__` placeholder, and both `darkmesh-setup` and
  `install-user-tools` decide per host. Default is by chassis (an internal
  battery means laptop, so off; no battery means headless, so on), overridable
  with `~/.config/darkmesh/protect-tailscale` containing `on` or `off`. On a
  headless node the reconnect owner now confirms failure, contains transfers,
  yields the optional VPN, restores required Tailscale, and prevents VPN
  re-entry until explicit operator rearm. Background: the 2026-06-23 entry in
  `docs/investigation-log.md`.

- **SSH over Chrome Remote Desktop (investigate + set up).** Chrome Remote Desktop is
  already governing invariant #2 (always reachable, in the VPN bypass list), so a remote
  shell that rides the same channel would be a strong fallback for when both SSH-over-
  Tailscale and the VPN are unavailable. CRD reportedly can carry SSH / a forwarded port;
  confirm the current mechanism on a macOS host (CRD headless host plus a forwarded port,
  a terminal inside the CRD desktop session, or a Google IAP / `gcloud` tunnel), pick the
  one that needs no always-on extra daemon (keep it event-driven), then document setup in
  `docs/runbook.md`. Goal: a remote shell that survives a Tailscale or VPN outage without
  depending on either.

- **Reference-laptop anomaly diagnostic** (from
  `docs/investigation-log.md`): the reference laptop does not exhibit the
  100.64 collision failure on the same Tailscale tailnet. Run
  `darkmesh-diag --window-seconds 60` on the reference laptop and diff the
  DNS resolver list + tunnel-address class against the headless host's capture
  from 2026-05-22. Find the meaningful difference (likely protocol
  negotiation outcome) and document it so other machines can replicate
  whichever side works.
- **Hostname resolution while VPN is on**: the auto-toggle disables
  MagicDNS during VPN connections. SSH-by-hostname doesn't work in
  that window. Consider a periodic `tailscale status --json` →
  `/etc/hosts` sync so `ssh headless-node` keeps working even with
  accept-dns off. Optional; the user accepted IP-based ssh as the
  short-term trade-off.
- **Stale 1.86.2 Tailscale extension cleanup on reboot**: macOS will
  finish uninstalling the old extension on next reboot, after which
  the `find_tailscale_extensions` helper will no longer find a stale
  entry. Verify after reboot; remove the `prune_stale_bypass_entries`
  step from the apply path only if it stops finding anything for a
  sustained period (it's defense-in-depth; safe to keep).
- **Network Lock = on, opportunistic**: currently relaxed. Investigate
  whether the new WireGuard + auto-toggle stack is robust enough to
  re-enable Network Lock without trapping internet on tunnel hiccups.
  Likely needs a healthcheck enhancement: if VPN goes Disconnected
  while Network Lock is true, auto-flip it false to prevent stranding.

## server_monitor integration brief (R1–R6) — 2026-06-16 handoff

The server_monitor agent left a local, untracked, real-names brief at
`docs/server-monitor-darkmesh-brief.md` (gitignored). Its asks, euphemized, with status:

- **R1 — make PF actually enforce + persist. DONE (code) 2026-06-16; deploy pending.**
  The root-LaunchDaemon idea was *rejected* as too invasive: a full `pfctl -f` reload to add
  a top-level reference would drop ExpressVPN's dynamically-inserted anchor (a connectivity
  risk, §1) and get clobbered on every reconnect. Instead, nest the rules under
  **`com.apple/vpn-guard`** so the always-present `com.apple/*` wildcard evaluates them —
  no reload, no clobber, no new daemon; a one-line anchor-path change in `vpn-guard.sh`
  (+ sudoers). `vpn-guard.sh` also ensures PF is enabled. Verified by probe on the M5. See
  the "PF kill-switch wired" item above.
- **R2 — publish PF state into the status file. DONE (code) 2026-06-16.** `vpn-guard.sh`
  writes a `/tmp/darkmesh-pf.json` sidecar (`pf_enabled`, `pf_anchor`, `pf_anchor_evaluated`,
  `pf_kill_active`, `checked_at`); the healthcheck merges it under the status file's `"pf"`
  key (same pattern as `reconnect`). server_monitor decodes it via `DarkmeshStatus.PFState`
  + `pfKillSwitchWired`. `darkmesh-audit` now FAILs when the anchor is not evaluated — it
  catches the exact loaded-but-dead state that previously showed green. A narrow read-only
  `pfctl -s info` NOPASSWD line was added (cheaper than a root writer; no blanket access).
- **R3 — one structured self-test.** DONE in code: `darkmesh-audit --json` owns the
  installed-stack, freshness, helper hash/authorization, breaker, and PF checks.
- **R4 — idempotent `darkmesh-repair`.** DONE in code: explicit operator action
  closes breakers, kickstarts both loops, and re-evaluates PF.
- **R5 — version the status schema.** DONE in code: schema 4 is additive and
  includes end-to-end/CRD probes, DNS override state, per-fault breakers, and a
  shared 60-second maximum age.
- **R6 — multi-device installer.** DONE: `install-user-tools` arms the full stack
  idempotently on any node (per-machine deploy still pending).

**Contract stability (do not break):** the `/tmp/darkmesh-status.json` keys, the launchd
labels (`com.user.darkmesh-{healthcheck,reconnect}`, `com.user.vpnguard`), and the helper
bins are a versioned contract server_monitor decodes. Rename keys/labels only with a
`schema` bump + a transition window (the `vpn_state` rename once cost an outage). Keep the
surface generic/file-based — server_monitor is PUBLIC and must never see real tool names.

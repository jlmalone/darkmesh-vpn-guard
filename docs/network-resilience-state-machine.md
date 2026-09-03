# Network resilience state machine

This document is the current ordering contract for laptop wake, network change,
captive access, filtered networks, and VPN failure. The older availability plan
still defines the safety hierarchy, but its global-probe gate and ExpressVPN
autoconnect guidance are superseded here.

## Policy order

1. Ordinary internet must recover automatically.
2. ExpressVPN is the preferred default route.
3. Tailscale is optional by default on a laptop. Its health and DNS integration
   never gate internet recovery. A headless `protect-tailscale=on` override or a
   successfully applied `tailscale-required-*` posture makes it higher priority
   than the commercial VPN until the operator applies a different compatible
   posture.
4. The transfer client is the only strict fail-closed component.
5. ExpressVPN Network Lock and built-in autoconnect stay off by default.

## States

| Phase | Entry action | Transition |
|---|---|---|
| `settling` | Coalesce network notifications and restore plain networking once for a new physical-network fingerprint. | Classify the plain path. |
| `desired-off` | Force transfer containment and restore plain networking. | `darkmesh-up` sets desired on. |
| `offline` | Leave VPN down. | A default interface and gateway appear. |
| `captive-standdown` | Leave VPN down and DHCP DNS in control. | Exact open-internet evidence appears. |
| `captive-clear-wait` | Require stable exact success before a normal-region VPN attempt. | Required clear samples pass. |
| `restricted-wait` | No positive portal evidence, but the normal probes are blocked or unavailable. | The initial plain-network window expires. |
| `retrying` | One serialized VPN attempt failed. Restore plain networking and preserve the absolute retry deadline. | Deadline expires. |
| `safety-standdown` | A connected tunnel failed the healthcheck safety gate. Prefer stable plain networking for one hour. | The standdown expires or the operator explicitly runs `darkmesh up`. |
| `plain-cooldown` | Per-network restricted-attempt budget is exhausted. | Cooldown expires or the physical network changes. |
| `connected` | Re-pin the transfer client to the live tunnel interface and address. The guard resumes only the hashes owned by the current incident after positive Wi-Fi trust, fresh internet and DNS health, exact tunnel-binding readback, and a direct tunnel probe all pass. | VPN or physical network changes. |

While ExpressVPN is disconnected, each reconcile pass also checks that the
Tailscale control state is online and a `100.64/10` sentinel route is owned by
the same `utun` interface as the saved Tailscale identity. Three consecutive failures trigger one saved VPN
service stop/start without `tailscale down`, preserving identity and preferences.
Automatic attempts are limited to one per hour.

When Tailscale is required, three confirmed failures make ExpressVPN yield only
after transfer containment is established. The reconnect owner then restores
Tailscale and records a priority standdown that keeps the optional VPN down
until an explicit `darkmesh up` rearm. A stopped
`WantRunning=false` backend is re-armed with a bounded settings-free
`tailscale up`; saved identity and all preferences are compared afterward.
Logout, reset, reauthentication, and application quit are never automatic. A
host-level Tailscale requirement also refuses any posture that forbids
Tailscale.

## Classification

A network is captive only when the Apple HTTP probe supplies positive evidence:
a redirect, HTTP 511, or an unexpected portal body. Failure to reach Apple,
Google, or a named global host is not captive evidence.

Two exact probe successes classify an ordinary open network. An active default
interface and gateway without positive captive evidence classify a restricted
network. This permits bounded VPN attempts where the VPN is needed to reach the
global probe hosts.

Restricted defaults:

- 15 seconds of restored plain networking before the first attempt;
- no more than two attempts per physical network in ten minutes;
- at least 60 seconds between attempts;
- 15 minutes of plain-network cooldown after the budget is exhausted.

The fingerprint contains the physical default interface, gateway, DHCP address,
and DHCP server identifier. VPN tunnel interfaces and DNS contents are excluded,
so VPN-generated path notifications cannot reset the attempt budget. A transient
sample with no physical default interface or gateway is ignored rather than
treated as a new network; this preserves the recovery budget while Wi-Fi or the
VPN route table is settling.

## Plain-network restoration

`darkmesh-restore-plain-network` is the one shared recovery primitive. It first
forces `vpn-guard` unsafe, which pauses the transfer client and loads only its
peer-port PF rules. It then disables ExpressVPN autoconnect and Network Lock,
disconnects ExpressVPN, restores any helper-owned DNS snapshot, disables
Tailscale DNS acceptance, and flushes DNS. If system DNS is still dead, the
existing journaled DHCP override is evaluated.

If transfer containment cannot be confirmed, the helper refuses to disconnect
the VPN or modify DNS. This preserves the transfer client's strict fail-closed
contract even when the installation itself is damaged.

The helper never changes `vpn-desired`, stops Tailscale, deletes tailnet routes,
or installs a machine-wide PF policy. Automatic recovery calls it without
changing intent. Manual captive, panic, and emergency commands set desired off
before calling it.

## Transfer incident ownership

Operator pause intent and network containment are separate state dimensions.
`~/.config/darkmesh/transfer-desired` is changed only by an explicit operator
pause or resume. Network automation never writes it.

Before an unsafe transition stops the transfer client, the guard inventories
the exact active hashes and atomically writes a mode-`0600` incident journal
under `~/.local/state/darkmesh/transfer-incidents/`. An unresolved journal is
never overwritten. If inventory is unavailable, the guard uses a non-resumable
pause fallback and stays fail-closed rather than guessing later.

Automatic recovery requires operator intent `active`, an explicitly trusted
current Wi-Fi gateway, fresh successful internet and DNS health, ExpressVPN's
connected tunnel, matching interface-and-address binding readback, and a direct fetch
bound to that tunnel. The guard keeps PF containment loaded through the first
check, flushes it, then repeats the recovery checks immediately before starting
only the journaled hashes. Failure re-arms PF. Successful targeted readback
closes the incident and retains a mode-`0600` history record. Items paused
before the incident are never part of that recovery set.

## Event and retry ownership

The long-running reconnect process is the only component allowed to issue VPN
connection attempts or restart ExpressVPN. A network-change signal sets a dirty
flag. Signals are coalesced before one reconcile pass and cannot interrupt an
absolute retry deadline, a connection observation window, or restart wait.

A healthcheck safety disconnect starts a one-hour automatic reconnect
standdown. This prevents a bad tunnel from repeatedly interrupting healthy
plain networking. `darkmesh up` records a fresh operator rearm and overrides
that standdown immediately.

The legacy `--once` path only forwards a signal to the long-running process.
ExpressVPN built-in autoconnect is disabled, and the configuration command hands
desired-on intent to `darkmesh-up` instead of connecting directly.

## Healthcheck relationship

The healthcheck remains the safety observer and status writer. A single global
probe failure reports degradation. Plain-network restoration requires two
consecutive post-grace failures where end-to-end access is down together with
DNS or raw IP access. Tailscale remains visible in status but does not trigger
VPN teardown on a laptop.

Observer liveness is a separate state dimension. Each tick writes a progress
heartbeat before any probe or recovery action. The supervisor marks the child
unresponsive after 90 seconds of silence, force-recycles it, and restarts it.
Status older than its published 60-second maximum is `STALE`, never GO or NO-GO.

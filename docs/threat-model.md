# Threat Model

## Protected Asset

Transfer-client traffic must not leave through physical Wi-Fi, Ethernet,
Tailscale, or any non-ExpressVPN path.

This includes:

- Peer traffic
- Discovery/control traffic
- Startup traffic
- Reconnect traffic
- Traffic after ExpressVPN disconnects or changes interface

## Allowed Exception

Tailscale itself may bypass ExpressVPN.

This exception exists so tailnet control traffic and peer traffic can work while
ExpressVPN remains connected (relaxed mode — Network Lock off).

## Non-Goals

This setup does not try to make the transfer client always available.

When safety and availability conflict, the transfer client should fail closed.

## Required Invariants

- The transfer client is never in ExpressVPN split-tunnel bypass rules.
- The transfer client is bound to the active ExpressVPN tunnel interface/address
  (this socket-binding — not Network Lock, which is off in relaxed mode — is the
  primary fail-closed control).
- The transfer client does **not** start paused: a paused headless session never
  announces or rechecks and nothing resumes it (it parked a transfer node for days);
  fail-closed is the socket-bind, not a pause.
- A staged coexistence experiment is the deliberate exception. Its preflight
  requires explicit paused intent, it keeps PF containment active, and it
  restores paused intent without starting a transfer. Resuming after report
  review is a separate operator action.
- The transfer client UPnP/NAT-PMP setting is disabled.
- `vpn-guard` handles unsafe network states (PF block on the transfer ports + pause/resume).

## Known Failure Mode

ExpressVPN may reconnect with a different `utun` interface or tunnel-side IP.

When that happens, the transfer client may appear stuck. This is safe if the
saved binding no longer matches the current ExpressVPN tunnel. Use:

```bash
transfer-vpn-doctor
```

Then refresh the binding only if the doctor says it is safe:

```bash
transfer-vpn-doctor --fix
```

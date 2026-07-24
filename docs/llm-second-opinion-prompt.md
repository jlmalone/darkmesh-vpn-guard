# Second-opinion prompt: ExpressVPN and Tailscale on macOS

Copy the section below into another review system. It contains synthetic host and
address examples so it can be shared publicly.

---

Challenge this analysis of a macOS networking failure. Identify incorrect
assumptions, missing evidence, and safer experiments.

## Goal

ExpressVPN provides the default public-internet tunnel. Tailscale provides remote
administration and must bypass ExpressVPN. A separate transfer client remains bound
to the ExpressVPN tunnel and must fail closed if that tunnel changes.

The combination fails on a headless test host but works on a reference laptop with
the same general software. Network Lock is disabled so a tunnel failure cannot
strand general internet access.

## Observed failure

ExpressVPN sometimes assigns both its tunnel and injected DNS resolver from
`100.64.0.0/10`, the same CGNAT range Tailscale uses. When the tunnel connects:

1. ExpressVPN installs a more-specific route through its `utun`.
2. The system resolver points to an address inside `100.64.0.0/10`.
3. Tailscale MagicDNS forwards to that system resolver.
4. The forwarded packet can follow the wrong tunnel and find no corresponding
   Tailscale peer.
5. Raw IP connectivity remains available, but system name resolution fails.

Representative sanitized log:

```text
dns udp query: waiting for response from [<vpn-resolver>]: deadline exceeded
open-conn-track: timeout opening <tailnet-address>:<port> => <vpn-resolver>:53
```

The ExpressVPN split-tunnel extension also logs that it “rejected” a UDP flow from
the bypass-listed Tailscale extension. This may mean pass-through rather than block
under NetworkExtension semantics; packet capture was not performed.

## Existing mitigation

Darkmesh disables Tailscale DNS acceptance while ExpressVPN is active, preserves
DHCP DNS off-tunnel, and watches raw-IP, named-fetch, system-DNS, Tailscale, and
remote-access health. When the connected path remains unusable, it first contains
the transfer client and then restores plain networking. Reconnect attempts are
serialized, rate-limited, captive-aware, and bounded by circuit breakers.

## Questions

1. Is the overlap between an ExpressVPN-assigned subnet and Tailscale’s
   `100.64.0.0/10` claim safely resolvable from macOS without fighting routes that
   the VPN client owns?
2. In `NETransparentProxyProvider` logging, does “provider rejected new flow”
   normally indicate pass-through or a blocked flow? What direct evidence would
   distinguish them?
3. Which sanitized diagnostics best explain why a reference laptop avoids the
   failure: protocol, VPN version, route ownership, DNS ordering, or interface
   binding?
4. Is disabling Tailscale MagicDNS while the commercial VPN is connected the
   safest durable design, or is there a better scoped DNS arrangement?
5. Which experiment would falsify the current collision hypothesis without
   risking remote lockout?

Keep internet connectivity and remote administration ahead of cosmetic VPN status.
The transfer client alone must remain strictly fail closed.

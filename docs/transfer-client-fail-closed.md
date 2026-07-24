# Transfer Client Fail-Closed Binding

## Why Binding Exists

ExpressVPN split tunneling lets Tailscale bypass the VPN.

That means the transfer client must be explicitly prevented from choosing
Tailscale or physical Wi-Fi. The primary control is the client's own interface
binding.

## Correct Binding

Bind the transfer client to the ExpressVPN tunnel, not `en0`.

Representative setup:

- ExpressVPN: `<vpn-utun>`, `<vpn-address>`
- Tailscale: `<tailscale-utun>`, `<tailnet-address>`
- Physical network: `<physical-interface>`

The helper writes these safety settings:

```text
Session\StartPaused=false
Session\Interface=<current ExpressVPN utun>
Session\InterfaceName=<current ExpressVPN utun>
Session\InterfaceAddress=<current ExpressVPN tunnel address>
Connection\UPnP=false
Session\LSD=false
```

The concrete config path and one section name are decoded at runtime so the
public source does not advertise the client or protocol identifiers.

For a compatible headless client, run `darkmesh-transfer-daemon` under a
`KeepAlive` launch supervisor and provide the daemon path through untracked
runtime configuration. The wrapper resolves the current ExpressVPN address
before starting the daemon, binds IPv4 to that address and IPv6 to loopback,
disables distributed peer discovery, local peer discovery, and port mapping,
and exits when the tunnel changes. The supervisor then restarts it against the
new tunnel.

## Why Not `en0`

`en0` is physical Wi-Fi.

Binding the transfer client to `en0` makes it eligible for the physical network
path. That is the opposite of the safety requirement.

## Stale Binding

If ExpressVPN reconnects and changes its tunnel interface or address, the
transfer client may stop transferring.

Run:

```bash
transfer-vpn-doctor
```

If it reports `STALE-BINDING`, refresh while the client is closed:

```bash
transfer-vpn-doctor --fix
```

Or:

```bash
transfer-vpn-doctor --fix --quit
```

The helper creates a timestamped backup before editing the client config.

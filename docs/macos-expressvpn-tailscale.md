# macOS ExpressVPN + Tailscale

## Working Approach

Use ExpressVPN's own split-tunnel support.

Bypass only:

- Tailscale app binary
- Tailscale network extension binary

Keep every other application, including the transfer client, inside ExpressVPN.

## Commands

```bash
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set networklock true
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl background enable
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set autoconnect true
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set splittunnel true
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set split-app bypass:/Applications/Tailscale.app/Contents/MacOS/Tailscale
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set split-app bypass:/Library/SystemExtensions/<UUID>/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension
```

The UUID under `/Library/SystemExtensions` changes. Use the helper instead of
typing it manually:

```bash
scripts/darkmesh-expressvpn-tailscale apply
```

## macOS Approval

ExpressVPN's split-tunnel network extension may require user approval.

Check:

```bash
systemextensionsctl list
```

Healthy state:

```text
com.expressvpn.vpn.splittunnel ... [activated enabled]
io.tailscale.ipn.macsys.network-extension ... [activated enabled]
```

If ExpressVPN is `waiting for user`, approve it in:

System Settings > General > Login Items & Extensions > Network Extensions

## Verification

```bash
scripts/darkmesh-expressvpn-tailscale verify
```

Healthy Tailscale output includes:

```text
UDP: true
Nearest DERP: Seattle
DERP latency:
```

Direct peer connections are nice but not required. DERP connectivity still means
Tailscale is usable.

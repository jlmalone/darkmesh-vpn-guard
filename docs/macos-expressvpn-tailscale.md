# macOS ExpressVPN + Tailscale

## Working Approach

Use ExpressVPN's own split-tunnel support.

Bypass only:

- Tailscale app binary
- Tailscale network extension binary

Keep every other application, including the transfer client, inside ExpressVPN.

## Commands

```bash
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set networklock false
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl background enable
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set autoconnect false
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set splittunnel true
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set split-app bypass:/Applications/Tailscale.app/Contents/MacOS/Tailscale
/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl set split-app bypass:/Library/SystemExtensions/<UUID>/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension
```

Darkmesh owns ExpressVPN connection ordering. Network Lock and ExpressVPN
autoconnect stay off so the VPN cannot trap general connectivity before the
bypass and recovery layers are ready.

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

### Approval boundary

The ExpressVPN CLI can configure split tunneling and request activation, but
macOS does not let a CLI approve a pending system extension on an unmanaged Mac.
The extension remains unavailable while `systemextensionsctl list` reports:

```text
com.expressvpn.vpn.splittunnel ... [activated waiting for user]
```

ExpressVPN may immediately turn Split Tunnel off after an unsuccessful attempt.
Do not repeat the toggle or reconnect the VPN. Keep the machine on the plain
network until the extension reports `activated enabled`.

Chrome Remote Desktop can render the system approval sheet with blank or
redacted rows. In that state, use the Mac's physical keyboard and display to
enable ExpressVPN under Network Extensions. Do not weaken system security,
modify protected approval databases, or enroll the Mac in device management
solely to avoid this one-time approval. Managed fleets can preapprove the
extension through a user-approved device-management system-extension policy.

After local approval, check the state before reconnecting:

```bash
systemextensionsctl list | grep -i com.expressvpn.vpn.splittunnel
```

Run the first reconnect from a console or with a tested plain-network rollback
path. If the reconnect drops Tailscale or remote access, use `darkmesh captive`
from the surviving console and leave ExpressVPN disconnected.

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

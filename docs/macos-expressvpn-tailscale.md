# macOS ExpressVPN + Tailscale

## Network boundary

Use ExpressVPN's own split-tunnel support.

Bypass only:

- Tailscale app binary
- Tailscale network extension binary

Keep every other application, including the transfer client, inside ExpressVPN.

## Install or upgrade on one Mac

Install the signed ExpressVPN and Tailscale apps and the signed Server Monitor
app first. Install Darkmesh from the Homebrew tap. Run commands below as the
signed-in user at the Mac, with a working plain-network recovery path.

```bash
brew install jlmalone/tap/darkmesh
darkmesh setup
darkmesh-expressvpn-tailscale apply
darkmesh-expressvpn-tailscale check-bypass
darkmesh audit
```

`darkmesh setup` configures the signed supervisor and scoped transfer
containment. It now exits with a failure if its final audit fails. On a fresh
install, that first audit may report a missing ExpressVPN bypass. Continue with
the next step at the local console, then require a passing audit before calling
the installation verified.

`apply` runs as the user, requests administrator authorization only for
ExpressVPN settings that actually need changing, then arms Darkmesh's VPN
reconnect intent. Do not run the whole helper under `sudo`: that would write
user state as root. It configures Tailscale's app and the running network
extension as bypasses, plus installed remote desktop host binaries. It never
bypasses the transfer client. ExpressVPN Network Lock stays off in ordinary
profiles; built-in autoconnect stays off so Darkmesh owns ordering.

The Tailscale extension path contains a changing installation UUID. A saved
rule for an old UUID does not protect the running extension. After every
Tailscale extension update, run `check-bypass` again. If it fails, it prints
the exact root-only `expressvpnctl set split-app bypass:<running-path>` command
to run locally. Then rerun `check-bypass` and `darkmesh audit`. Darkmesh refuses
a new VPN connection under a Tailscale-required posture while the exact rule
is missing.

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

Run the first reconnect from a console or with a tested plain-network recovery
path. If the reconnect drops Tailscale or remote access, use `darkmesh captive`
from the surviving console and leave ExpressVPN disconnected.

## Verification

```bash
darkmesh-expressvpn-tailscale verify
darkmesh audit
darkmesh status
transfer-vpn-doctor --check
```

Require a fresh Darkmesh status, internet and DNS access, an exact bypass rule,
Tailscale's own node online, and one reachable tailnet peer. Check transfer
binding against the live ExpressVPN tunnel. A temporary `GO` does not establish
long-term stability. Keep the ordinary profile active while checking for
post-connect failures.

Tailscale may report a `MagicSock ReceiveIPv4` warning while peer traffic still
works. Keep the warning visible and test a real peer; online control state alone
does not prove that the receive path works. Do not turn an otherwise satisfied
posture red solely from the warning, and do not treat the warning as harmless
without a peer check.

Healthy Tailscale netcheck output often includes:

```text
UDP: true
Nearest DERP: <region>
DERP latency:
```

Direct peer connections are optional. A working DERP path can carry peer traffic.
The fixed `100.64.0.1` route is not a valid universal Tailscale health check:
macOS may route only assigned self and peer addresses through the extension.
Darkmesh checks the current self address's tunnel route instead.

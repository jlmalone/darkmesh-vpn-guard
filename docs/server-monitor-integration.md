# server_monitor Integration

`server_monitor` should not implement network policy. It displays state from
`darkmesh-healthcheck` and offers clear diagnostics.

## Current implementation (2026-05-22)

`darkmesh-healthcheck` writes `/tmp/darkmesh-status.json` every 10s. The
schema is *flat* (not the nested suggestion below) — see the
`darkmesh-healthcheck` source or any sample status file for the exact field
names. `server_monitor`'s `DarkmeshStatusMonitor` consumes this directly.

### server_monitor source changes

The Swift menu-bar app (`~/ios_code/server_monitor`) gained three files in
`app/ServerMonitor/ServerMonitor/`:

- `Models/DarkmeshStatus.swift` — Codable struct mirroring the JSON
- `ViewModels/DarkmeshStatusMonitor.swift` — ObservableObject polling every 5s
- `Views/DarkmeshStatusView.swift` — SwiftUI panel: verdict header, four-probe
  grid, last-auto-disconnect footnote

`ServerMonitorApp.swift` was updated to:

- Instantiate `@StateObject private var darkmesh = DarkmeshStatusMonitor()`
- Embed `DarkmeshStatusView(monitor: darkmesh)` at the top of the menu-bar
  dropdown
- Tint the menu-bar icon with the worst color of (services, darkmesh) so the
  user sees red/yellow/green at a glance

### Build + install

Requires full Xcode (Command Line Tools alone is not enough — SwiftUI app
bundles need the macOS SDK from Xcode.app). Once Xcode is installed:

```bash
cd ~/ios_code/server_monitor
xcodebuild -project app/ServerMonitor/ServerMonitor.xcodeproj \
           -scheme ServerMonitor -configuration Release \
           build SYMROOT=build
cp -R build/Release/ServerMonitor.app /Applications/
open /Applications/ServerMonitor.app
```

For a signed + notarized release DMG, use `scripts/build_release.sh` in the
server_monitor repo (requires Apple Developer credentials in `.env`).

### No-Xcode fallback: SwiftBar plugin

When Xcode isn't available, install SwiftBar — same darkmesh status in the
menu bar, no compilation:

```bash
brew install --cask swiftbar
~/IdeaProjects/darkmesh-vpn-guard/scripts/install-user-tools   # installs the plugin
open -a SwiftBar
```

The plugin is at `swiftbar/darkmesh.10s.sh` in the darkmesh-vpn-guard repo
and reads the same `/tmp/darkmesh-status.json` file.

## Original schema proposal (kept for reference)

`vpn-guard` should write:

```text
~/Library/Application Support/vpn-guard/state.json
```

Suggested schema:

```json
{
  "schema": 1,
  "verdict": "GO",
  "reason": "ok",
  "expressvpn": {
    "connected": true,
    "networkLock": true,
    "splitTunnel": true,
    "region": "example-region",
    "interface": "<vpn-utun>",
    "interfaceAddress": "<vpn-address>"
  },
  "tailscale": {
    "healthy": true,
    "interface": "<tailscale-utun>",
    "ip": "<tailnet-address>",
    "udp": true,
    "nearestDerp": "Example relay"
  },
  "transferClient": {
    "running": false,
    "boundInterface": "<vpn-utun>",
    "boundAddress": "<vpn-address>",
    "bindingMatchesExpressVPN": true,
    "startPaused": true,
    "upnp": false
  },
  "pf": {
    "unsafeAnchorLoaded": false
  },
  "lastRun": "2026-05-05T22:19:58Z"
}
```

## UI Behavior

GO:

- ExpressVPN connected.
- Transfer client not bypassed.
- Transfer-client binding matches ExpressVPN tunnel.
- Tailscale healthy or at least reachable.

(Network Lock is **off** in relaxed mode — not a GO/NO-GO criterion; the PF anchor
+ socket-binding provide fail-closed.)

NO-GO:

- ExpressVPN disconnected.
- Transfer client appears in ExpressVPN split-app rules.
- Transfer-client binding points at Tailscale or Wi-Fi.
- Transfer-client binding is stale.
- vpn-guard unsafe PF anchor loaded.

## User-Facing Explanation

If the transfer client is stuck because the tunnel changed, show:

```text
The transfer client is fail-closed. Its saved VPN binding no longer matches the
current ExpressVPN tunnel. Run transfer-vpn-doctor --fix after quitting the
client.
```

That distinction matters: stale binding is not a leak, but the user needs to know
why transfers stopped.

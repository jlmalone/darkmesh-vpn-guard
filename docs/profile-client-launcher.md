# Profile-based client launcher

`scripts/launch-profile-client.main.kts` supervises a client that stores its
settings in an explicit profile. It requires Kotlin/JVM and the existing
privileged Darkmesh bootstrap. It does not modify VPN or Tailscale state.

The launcher requires a connected, identifiable VPN tunnel. Before starting the
client, it refreshes and checks the binding through `transfer-vpn-doctor`. It
refuses to edit a profile when the configured client process already exists.
Only one launcher may hold its state-directory lock. A changed or unavailable
tunnel stops the owned client, allowing its supervisor to retry later.

Configure these environment variables in the private service definition:

| Variable | Meaning |
| --- | --- |
| `TRANSFER_CLIENT_BIN` | Absolute path to the executable |
| `TRANSFER_CLIENT_ARGUMENTS_FILE` | Absolute path to a file containing one literal argument per line |
| `TRANSFER_CLIENT_STATE_DIR` | Absolute directory for the launcher lock and temporary control output |
| `TRANSFER_CLIENT_PROCESS` | Optional process name for the preflight check, at most 15 characters; defaults to the executable name |
| `DARKMESH_CLIENT_CONF` | Existing private binding-tool configuration for this profile |
| `TRANSFER_BINDING_TOOL` | Optional absolute binding-tool path |
| `EXPRESSVPN_CTL` | Optional absolute vendor-control path |
| `TRANSFER_CLIENT_RUNTIME_MANIFEST` | Optional absolute path to a runtime-library checksum manifest |

Arguments are passed directly to the executable and never evaluated as shell
code. Keep the argument file and client configuration private. The service
definition must supply any runtime plugin paths required by its chosen client.
The guard can use an existing client-side localhost authentication bypass for
loopback HTTP endpoints. It does not enable that bypass; other endpoints keep
using Keychain credentials.

For clients using private library APIs, supply a runtime manifest. Each line
contains a lowercase SHA-256, a tab, and the absolute library path. A mismatch
refuses startup with an instruction to rebuild the client. This prevents a
dependency upgrade from silently loading an incompatible library.

Run the launcher at low priority under one service owner. Use a retry throttle
and allow at least 30 seconds for graceful service shutdown. Startup exits with
75 when the VPN is unavailable or changes, and 69 when configuration or binding
validation fails. An ordinary client exit preserves that client's exit code.

Network binding is the primary containment mechanism. The existing scoped PF
rules remain defense in depth. A passing launch does not prove that the client
has complete files, successful service responses, or live transfers; verify
those separately before switching an active workload.

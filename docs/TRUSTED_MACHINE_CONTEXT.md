# Trusted-machine context

The tracked repository and release payload are public. Machine-specific context remains
outside Git.

## Context classes

- `AI.local.md` records private topology, historical operator context, and the forbidden
  terms used during public-content scans.
- `~/.config/darkmesh/transfer-client.conf` identifies the local transfer implementation
  and its runtime paths.
- `~/.config/darkmesh/protect-tailscale` selects the per-host remote-access policy.
- SSH keys, tokens, passwords, Keychain values, diagnostic logs, transfer definitions,
  and activity history are secrets or operational data, not agent context.

## Propagation

Use an authenticated encrypted channel such as Tailscale SSH. Keep agent context mode
`0600`, run both sides of the transfer at low priority, and compare with the destination
before replacing it.

```bash
chmod 600 AI.local.md
nice -n 19 rsync -a --chmod=F600 --rsync-path='nice -n 19 rsync' \
  AI.local.md "$TRUSTED_HOST:$DARKMESH_CHECKOUT/"
```

Runtime configuration is per host. Copy it to a temporary destination name, review
client paths, process names, ports, and policy on that host, then install it deliberately.
Never propagate SSH private keys, Keychain contents, credentials, live diagnostic logs,
or transfer activity through this mechanism.

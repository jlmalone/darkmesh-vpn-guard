# Contributing

Darkmesh is a macOS network-resilience toolkit. Changes must preserve ordinary internet
connectivity, remote recovery, and the transfer client's fail-closed boundary.

## Before opening a change

- Read `docs/network-resilience-state-machine.md` and `docs/threat-model.md`.
- Keep ExpressVPN Network Lock off unless the change explicitly targets strict mode.
- Do not add host names, user names, private network addresses, real workload names, or
  transfer-client product details to tracked content.
- Put machine-specific integration values in
  `~/.config/darkmesh/transfer-client.conf`, using
  `transfer-client.conf.example` as the template.
- Preserve the schema of `/tmp/darkmesh-status.json`. Coordinate any intentional schema
  bump with consumers.

## Testing

Run syntax checks and the complete mocked test suite:

```bash
find scripts tests vpn-guard -type f -name '*.sh' -o -type f -perm -u+x |
  while IFS= read -r file; do bash -n "$file"; done

for test in tests/*.sh; do
  bash "$test"
done
```

Tests mock macOS network state and must not change the host's live VPN, DNS, routes, or
packet-filter configuration. Live validation belongs in an explicitly scoped operator
test after the mocked suite passes.

## Pull requests

Keep each pull request focused. Explain the failure mode, the governing invariant, the
test coverage, and any manual macOS validation still required. Never include live
diagnostic bundles without reviewing them for machine-specific data first.

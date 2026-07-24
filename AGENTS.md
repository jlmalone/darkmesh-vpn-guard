# AGENTS.md

Authoritative repository instructions for darkmesh VPN guard.

Apply any machine-level instructions first, then this repository file.

## Purpose

This repository contains the network self-healing, Tailscale and commercial-VPN coexistence, and
transfer-client fail-closed toolkit for the macOS machine fleet.

Its read-only display counterpart is the separate `server_monitor` project. The two share a
versioned `/tmp/darkmesh-status.json` contract. Bump `schema` and tolerate or warn on mismatch.
Never rename keys silently.

Read durable repository docs in this order:

1. `docs/network-resilience-state-machine.md`
2. `docs/availability-recovery-plan.md`
3. `ROADMAP.md`
4. `docs/runbook.md`
5. `README.md`

## Tracked-content scrub

The source repository is private, but its release tarball is published through a public Homebrew
tap. Treat tracked content and git history as public.

Operator-specific real names must not enter tracked source, docs, comments, string literals, commit
messages, or history. Use neutral tracked terms such as:

- `transfer`
- `transfer client`
- `serve`
- `external store`
- `$VPN_CLIENT`
- `host-a`, `host-b`, `host-c`

Tailscale and the commercial VPN may be named openly because they are the subject of the toolkit.

The exact local mapping lives in gitignored `AI.local.md`. Runtime values live in untracked
`~/.config/darkmesh/transfer-client.conf`. Contributors use `transfer-client.conf.example`.

Scrub only version-controlled content:

| Location | Real operator values |
|---|---|
| Tracked source, docs, comments, strings | Never |
| Commit messages and history | Never |
| Runtime output, filesystem paths, logs | Allowed |
| Gitignored local files and runtime config | Allowed |

Do not waste effort rewriting runtime output or gitignored files. Verify the tracked tree with the
forbidden list from `AI.local.md`. If history needs repair, use a deliberate history rewrite and
verify a fresh clone. Read `docs/TRUSTED_MACHINE_CONTEXT.md` before propagating private context or
runtime configuration.

## Governing invariants

The full contract is `docs/availability-recovery-plan.md` section 1. Priority order:

1. Internet connectivity is paramount. The tool must not self-inflict a general outage.
2. Chrome Remote Desktop remains reachable.
3. Only the transfer client's peer traffic is hard fail-closed, scoped to its ports and non-VPN paths.
4. VPN-everywhere is best effort.
5. Green status is informational. Non-green status does not block general connectivity.

The commercial VPN's network lock remains off. DNS stays DHCP-provided and off-tunnel so captive
portals remain usable.

## Administrator privilege

One administrator bootstrap per machine may install fixed root-owned helpers, rules, and narrowly
scoped passwordless commands.

Normal setup reruns, upgrades, supervisor migration, recovery, and configuration changes must reuse
the existing bootstrap. Request administrator approval again only when a root-owned artifact or its
scoped privilege contract genuinely changes or is missing. Explain the exact change before prompting.

Never broaden privilege merely to avoid a prompt.

## Development and release

- Run remote work with `nice -n 19`.
- Preserve the status schema shared with `server_monitor`.
- Verify live interface names and service ownership before editing configuration.
- Build release artifacts from committed source.
- Keep binaries in GitHub Releases, not in git.

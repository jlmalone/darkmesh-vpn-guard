# Confirmed Apply rejected by a hidden host requirement

## Problem

A local operator selected VPN required, Tailscale forbidden and confirmed
Apply. The producer returned `applied=false`, `host-policy-conflict` because
`protect-tailscale=on` was saved from an earlier setup. The desired and enforced
profiles remained Tailscale required, VPN optional, with `vpn-desired=off`.
Manual vendor connections were then disconnected by the desired-off supervisor.

Two additional paths could defeat a replacement: the healthcheck retained
`--protect-tailscale` in its startup arguments, and the reconnect supervisor
attempted optional Tailscale repair even when the selected profile forbade it.

## Permanent correction

Confirmed local Apply supplies `--replace-host-policy`. After capability and
fresh transfer-containment preflights, a conflicting host requirement is
atomically replaced with `off` and recorded in the action receipt. Ordinary
CLI calls without the option still refuse conflicting profiles.

The healthcheck reads the saved requirement every tick. Explicit off overrides
stale startup arguments, while enforced Tailscale-required profiles still take
priority. Both supervisors recognize all Tailscale-forbidden profiles, and the
reconnect owner skips optional repair for them. VPN rearm remains owned by the
existing supervisor. No competing connection loop is introduced.

## Recovery and evidence

Install the corrected release, configure the confirmed Apply command as shown
in the Server Monitor network example, and apply the intended profile. Verify
the apply receipt, desired and enforced profiles, VPN intent, actual connection,
internet/DNS, and transfer containment. An applied policy with unmet requirements
must be reported as unconverged. A successful short observation does not prove
future uptime, sleep/wake recovery, or a reboot.

To restore private-overlay priority, apply a Tailscale-required profile. To
restore the extra host guard, explicitly save `protect-tailscale=on`. The
Tailscale-forbidden posture disconnects overlay access, so it must be selected
from a local control path. Unit tests are deferred under RAPID POC.

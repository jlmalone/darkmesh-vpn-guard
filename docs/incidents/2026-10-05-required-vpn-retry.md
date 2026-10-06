# Required VPN suppressed by optional-VPN safety pause

The healthcheck observed repeated internet reachability failures through a
connected VPN and restored plain connectivity. DNS remained healthy. The
reconnect owner then imposed its unconditional one-hour safety pause even
though the applied profile required VPN and desired intent remained on.
The exact tunnel failure was not established by the retained probe output.

Required-VPN profiles now use a 60-second settling window after an automatic
disconnect, followed by the existing stable-open-internet gate and serialized
connection retries. Optional profiles retain the one-hour pause. The window is
selected from the current enforced profile on each check, so a policy change
does not require a process restart. Captive/offline handling, transfer
containment, retry backoff, app-restart caps, and circuit-breaker recovery remain
in force. The shorter pause does not bypass the healthcheck or claim a tunnel
is healthy merely because the vendor reports Connected.

Verification uses shell syntax, source review, and live recovery under the
existing supervisor. Unit tests remain deferred under RAPID POC. No deliberate
network outage is required for rollout; an already-disconnected required VPN
provides the live recovery case. Long-term uptime remains a separate observation.

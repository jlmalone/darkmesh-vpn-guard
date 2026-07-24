#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-status-tests)"
trap 'rm -rf "$TMP"' EXIT
STATUS="$TMP/status.json"
OLD="$(date -u -v-26H +%FT%TZ)"

cat > "$STATUS" <<EOF
{"schema":4,"timestamp":"$OLD","max_age_seconds":60,"verdict":"GO","vpn_state":"Connected","expressvpn_state":"Connected","internet_ok":true,"dns_ok":true,"tailscale_ok":true,"auto_disconnected":false,"auto_disconnect_reason":"","auto_disconnect_at":"","pf":{"pf_anchor_evaluated":true}}
EOF

set +e
cli="$(DARKMESH_STATUS_FILE="$STATUS" "$ROOT/scripts/darkmesh" status 2>&1)"
rc=$?
set -e
[[ "$rc" == 3 ]] || { echo "FAIL: stale CLI exit=$rc" >&2; exit 1; }
[[ "$cli" == verdict=STALE*last=GO@* ]] || { echo "FAIL: stale CLI output: $cli" >&2; exit 1; }

bar="$(DARKMESH_STATUS_FILE="$STATUS" bash "$ROOT/swiftbar/darkmesh.10s.sh")"
grep -q '^❔ STALE$' <<< "$bar" || { echo "FAIL: SwiftBar did not show STALE" >&2; exit 1; }
if grep -q '^🟢 GO$' <<< "$bar"; then
  echo "FAIL: SwiftBar showed cached green" >&2
  exit 1
fi

echo "PASS: stale status is never displayed as green"

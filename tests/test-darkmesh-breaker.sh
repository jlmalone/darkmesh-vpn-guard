#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-breaker-test)"
trap 'rm -rf "$TMP"' EXIT

export DARKMESH_BREAKER_FILE="$TMP/breakers.json"
# shellcheck source=scripts/darkmesh-breaker
source "$ROOT/scripts/darkmesh-breaker"

breaker_init
/usr/bin/plutil -p "$DARKMESH_BREAKER_FILE" >/dev/null
[[ "$(breaker_get dns_dead state missing)" == closed ]] || {
  echo "fresh breaker state was not closed" >&2
  exit 1
}

breaker_update dns_dead state string open rung integer 3 gave_up bool true
[[ "$(breaker_get dns_dead state missing)" == open ]] || {
  echo "breaker update was not persisted" >&2
  exit 1
}

cat > "$DARKMESH_BREAKER_FILE" <<'JSON'
{
  "schema": 1,
  "breakers": {
    "dns_dead": {
      "state": "open", "rung": 4, "cycles": 2, "dead_ticks": 8,
      "window_started_at": 1, "opened_at": 2, "alerted_at": 3,
      "gave_up": true, "recover_refail_count": 1,
      "last_action": "gave-up", "last_action_at": 4
    },
    "crd_wedged": {
      "state": "closed", "rung": 0, "cycles": 0, "dead_ticks": 0,
      "window_started_at": 0, "opened_at": 0, "alerted_at": 0,
      "gave_up": false, "recover_refail_count": 0,
      "last_action": "", "last_action_at": 0
    }
  }
}
JSON

reject_json_plutil="$TMP/plutil"
cat > "$reject_json_plutil" <<'SH'
#!/bin/bash
if [[ "$1" == -p ]] && head -c 1 "$2" | grep -q '{'; then
  exit 1
fi
exec /usr/bin/plutil "$@"
SH
chmod +x "$reject_json_plutil"
BREAKER_PLUTIL="$reject_json_plutil"

breaker_init
"$BREAKER_PLUTIL" -p "$DARKMESH_BREAKER_FILE" >/dev/null
[[ "$(breaker_get dns_dead state missing)" == open ]] || {
  echo "JSON migration did not preserve breaker state" >&2
  exit 1
}
[[ "$(breaker_get dns_dead rung missing)" == 4 ]] || {
  echo "JSON migration did not preserve breaker rung" >&2
  exit 1
}

echo "PASS: breaker state is plist-compatible and legacy JSON migrates without reset"

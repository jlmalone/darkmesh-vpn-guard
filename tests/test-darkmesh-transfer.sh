#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-transfer-test)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; HOME_DIR="$TMP/home"; REQUESTS="$TMP/requests.log"
mkdir -p "$BIN" "$HOME_DIR/.config/darkmesh"
fail() { echo "FAIL: $*" >&2; exit 1; }
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

stub security 'exit 1'
stub netstat '
[[ "${TEST_TUNNEL:-0}" == 1 ]] && printf "0/1 100.64.0.1 UGSc utun8\n"
exit 0'
stub ifconfig '
[[ "${TEST_TUNNEL:-0}" == 1 && "${1:-}" == utun8 ]] && printf "\tinet 100.64.100.6 netmask 0xffffffff\n"
exit 0'
stub pkill 'printf "%s\n" "$*" >> "${TEST_SIGNALS:?}"'
stub curl '
printf "%s\n" "$*" >> "${TEST_REQUESTS:?}"
[[ "${TEST_API_FAIL:-0}" == 1 ]] && exit 1
[[ "$*" == *"/api/v2/app/version"* ]] && { echo 5.0; exit 0; }
[[ "$*" == *"/api/v2/items/info"* ]] && { echo "[]"; exit 0; }
[[ "$*" == *"/api/v2/app/preferences"* ]] && {
  printf "{\"current_network_interface\":\"%s\",\"current_interface_address\":\"%s\"}\n" \
    "${TEST_BOUND_INTERFACE:-}" "${TEST_BOUND_ADDRESS:-}"
  exit 0
}
[[ "$*" == *"/api/v2/items/stop"* || "$*" == *"/api/v2/items/start"* ]] && exit 0
exit 1'
stub incident '
case "${1:-}" in
  pending) [[ "${TEST_PENDING:-0}" == 1 ]] ;;
  recover) printf "recover\n" >> "${TEST_INCIDENT_LOG:?}" ;;
  *) exit 0 ;;
esac'

CONF="$HOME_DIR/.config/darkmesh/transfer-client.conf"
cat > "$CONF" <<'EOF'
CLIENT_APP="TestTransferClient"
CLIENT_PROC="TestTransferClient"
CLIENT_API_BASE="items"
CLIENT_WEB_HOST="http://127.0.0.1:18080"
EOF
chmod 600 "$CONF"
DESIRED="$HOME_DIR/.config/darkmesh/transfer-desired"
INCIDENT_LOG="$TMP/incident.log"

run_transfer() {
  HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TEST_REQUESTS="$REQUESTS" \
    TEST_PENDING="${TEST_PENDING:-0}" TEST_API_FAIL="${TEST_API_FAIL:-0}" \
    TEST_TUNNEL="${TEST_TUNNEL:-0}" TEST_BOUND_INTERFACE="${TEST_BOUND_INTERFACE:-}" \
    TEST_BOUND_ADDRESS="${TEST_BOUND_ADDRESS:-}" \
    TEST_INCIDENT_LOG="$INCIDENT_LOG" TEST_SIGNALS="$TMP/signals.log" DARKMESH_CLIENT_CONF="$CONF" \
    DARKMESH_TRANSFER_DESIRED="$DESIRED" DARKMESH_TRANSFER_STATUS="$TMP/status.json" \
    DARKMESH_TRANSFER_INCIDENT_CTL="$BIN/incident" \
    bash "$ROOT/scripts/darkmesh-transfer" "$@"
}

echo "1. explicit operator pause owns global intent"
run_transfer pause >/dev/null
[ "$(cat "$DESIRED")" = paused ] || fail "operator pause intent was not persisted"
grep '/api/v2/items/stop' "$REQUESTS" | grep -F 'hashes=all' >/dev/null \
  || fail "explicit operator pause did not stop the full set"

echo "2. pending incident routes resume through exact incident recovery"
: > "$REQUESTS"; TEST_PENDING=1
run_transfer resume >/dev/null
[ "$(cat "$DESIRED")" = active ] || fail "operator active intent was not persisted"
[ "$(cat "$INCIDENT_LOG")" = recover ] || fail "pending incident was not delegated to its owner"
! grep '/api/v2/items/start' "$REQUESTS" >/dev/null \
  || fail "pending incident used broad resume"

echo "3. no incident permits the operator's explicit broad resume"
: > "$REQUESTS"; TEST_PENDING=0
run_transfer resume >/dev/null
grep '/api/v2/items/start' "$REQUESTS" | grep -F 'hashes=all' >/dev/null \
  || fail "explicit broad resume was not issued without an incident"
grep -F -- '-CONT -x TestTransferClient' "$TMP/signals.log" >/dev/null \
  || fail "explicit broad resume did not clear a SIGSTOP fallback"

echo "4. active intent can be repaired without broad resume"
: > "$REQUESTS"
printf 'paused\n' > "$DESIRED"
run_transfer activate >/dev/null
[ "$(cat "$DESIRED")" = active ] || fail "active intent was not persisted"
[ "$(stat -f %Lp "$DESIRED")" = 600 ] || fail "active intent was not private"
! grep '/api/v2/items/start' "$REQUESTS" >/dev/null \
  || fail "intent-only activation started transfers"

echo "5. API failure is reported instead of claiming success"
TEST_API_FAIL=1
if run_transfer pause >/dev/null 2>&1; then fail "failed pause claimed success"; fi
[ "$(cat "$DESIRED")" = paused ] || fail "failed API call lost operator pause intent"

echo "6. status requires both the current tunnel interface and address"
TEST_API_FAIL=0; TEST_TUNNEL=1; TEST_BOUND_ADDRESS=100.64.100.6
TEST_BOUND_INTERFACE=utun5
out="$(run_transfer status --json)"
[ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["on_tunnel"]).lower())')" = false ] \
  || fail "same-address stale interface was reported on-tunnel"
TEST_BOUND_INTERFACE=utun8
out="$(run_transfer status --json)"
[ "$(printf '%s' "$out" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["on_tunnel"]).lower())')" = true ] \
  || fail "matching interface and address were not reported on-tunnel"

echo "PASS: operator transfer intent tests"

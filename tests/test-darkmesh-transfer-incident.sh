#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-transfer-incident-test)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
HOME_DIR="$TMP/home"
STATE="$TMP/client-state.json"
STARTED="$TMP/client-started.json"
REQUESTS="$TMP/requests.log"
mkdir -p "$BIN" "$HOME_DIR/.config/darkmesh"

fail() { echo "FAIL: $*" >&2; exit 1; }
stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "$body" > "$BIN/$name"
  chmod +x "$BIN/$name"
}

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
C="cccccccccccccccccccccccccccccccccccccccc"
cat > "$STATE" <<EOF
[
  {"hash":"$A","state":"working"},
  {"hash":"$B","state":"stalledUP"},
  {"hash":"$C","state":"stoppedDL"}
]
EOF
cat > "$STARTED" <<EOF
[
  {"hash":"$A","state":"working"},
  {"hash":"$B","state":"stalledUP"},
  {"hash":"$C","state":"stoppedDL"}
]
EOF

stub pgrep 'exit 0'
stub security 'exit 1'
stub trust-ok 'exit 0'
stub trust-fail 'exit 1'
stub vpn-ok 'exit 0'
stub vpn-fail 'exit 1'
stub incident-expressvpnctl '
[[ "$*" == *"status"* ]] && echo "Connected to test-location"
exit 0'
stub netstat 'printf "0/1 100.64.0.1 UGSc utun8\n"'
stub ifconfig '
[[ "${1:-}" == utun8 ]] && printf "\tinet 100.64.100.6 netmask 0xffffffff\n"
exit 0'
stub networksetup 'printf "Hardware Port: Wi-Fi\nDevice: en0\n"'
stub route 'printf "   gateway: 192.0.2.1\n interface: en0\n"'
stub arp 'printf "? (192.0.2.1) at 00:11:22:33:44:55 on en0 ifscope [ethernet]\n"'
stub curl '
printf "%s\n" "$*" >> "${TEST_REQUESTS:?}"
if [[ "$*" == *"/api/v2/app/version"* ]]; then echo 5.0; exit 0; fi
if [[ "$*" == *"/api/v2/app/preferences"* ]]; then
  printf "{\"current_network_interface\":\"%s\",\"current_interface_address\":\"100.64.100.6\"}\n" \
    "${TEST_BOUND_INTERFACE:-utun8}"
  exit 0
fi
if [[ "$*" == *"generate_204"* ]]; then echo 204; exit 0; fi
if [[ "$*" == *"/api/v2/items/info"* ]]; then cat "${TEST_STATE:?}"; exit 0; fi
if [[ "$*" == *"/api/v2/items/stop"* || "$*" == *"/api/v2/items/pause"* ]] && [[ "${TEST_STOP_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *"/api/v2/items/stop"* && "${TEST_MODERN_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *"/api/v2/items/stop"* || "$*" == *"/api/v2/items/pause"* ]]; then exit 0; fi
if [[ "$*" == *"/api/v2/items/start"* && "${TEST_MODERN_FAIL:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *"/api/v2/items/start"* || "$*" == *"/api/v2/items/resume"* ]]; then
  cp "${TEST_STARTED:?}" "${TEST_STATE:?}"
  exit 0
fi
exit 1'

CONF="$HOME_DIR/.config/darkmesh/transfer-client.conf"
cat > "$CONF" <<'EOF'
CLIENT_PROC="TestTransferClient"
CLIENT_API_BASE="items"
CLIENT_WEB_HOST="http://127.0.0.1:18080"
EOF
chmod 600 "$CONF"
printf 'active\n' > "$HOME_DIR/.config/darkmesh/transfer-desired"

run_incident() {
  HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    DARKMESH_CLIENT_CONF="$CONF" \
    DARKMESH_TRANSFER_INCIDENT_DIR="$HOME_DIR/.local/state/darkmesh/transfer-incidents" \
    DARKMESH_TRANSFER_DESIRED="$HOME_DIR/.config/darkmesh/transfer-desired" \
    DARKMESH_TRUST_VERIFY_CMD="${TEST_TRUST_CMD:-$BIN/trust-ok}" \
    DARKMESH_VPN_VERIFY_CMD="${TEST_VPN_CMD-$BIN/vpn-ok}" \
    DARKMESH_STATUS_FILE="$HOME_DIR/status.json" EXPRESSVPN_CTL="$BIN/incident-expressvpnctl" \
    TEST_REQUESTS="$REQUESTS" TEST_STATE="$STATE" TEST_STARTED="$STARTED" \
    TEST_BOUND_INTERFACE="${TEST_BOUND_INTERFACE:-utun8}" \
    TEST_MODERN_FAIL="${TEST_MODERN_FAIL:-0}" \
    TEST_STOP_FAIL="${TEST_STOP_FAIL:-0}" \
    bash "$ROOT/scripts/darkmesh-transfer-incident" "$@"
}

echo "1. containment journals and stops only the exact active set"
run_incident contain vpn-disconnect >/dev/null
JOURNAL="$HOME_DIR/.local/state/darkmesh/transfer-incidents/active.json"
[ -f "$JOURNAL" ] || fail "active incident journal missing"
[ "$(stat -f %Lp "$JOURNAL")" = 600 ] || fail "journal mode is not 0600"
[ "$(stat -f %Lp "$(dirname "$JOURNAL")")" = 700 ] || fail "state directory mode is not 0700"
python3 - "$JOURNAL" "$A" "$B" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert data["status"] == "contained"
assert data["active_hashes"] == [sys.argv[2], sys.argv[3]]
PY
grep '/api/v2/items/stop' "$REQUESTS" | grep -F "hashes=$A%7C$B" >/dev/null \
  || grep '/api/v2/items/stop' "$REQUESTS" | grep -F "hashes=$A|$B" >/dev/null \
  || fail "targeted stop did not contain exactly A and B"
! grep '/api/v2/items/stop' "$REQUESTS" | grep -F "$C" >/dev/null \
  || fail "pre-paused C was included in containment"

echo "2. repeated containment preserves the original incident"
before="$(shasum -a 256 "$JOURNAL" | awk '{print $1}')"
run_incident contain repeated >/dev/null
after="$(shasum -a 256 "$JOURNAL" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "repeated containment overwrote the incident"
[ "$(grep -c '/api/v2/items/stop' "$REQUESTS")" -eq 2 ] || fail "repeated containment did not reassert the exact stop"

echo "3. operator pause and missing trust independently block recovery"
printf 'paused\n' > "$HOME_DIR/.config/darkmesh/transfer-desired"
if run_incident recover >/dev/null 2>&1; then fail "operator pause allowed incident recovery"; fi
[ -f "$JOURNAL" ] || fail "operator pause consumed the journal"
printf 'active\n' > "$HOME_DIR/.config/darkmesh/transfer-desired"
TEST_TRUST_CMD="$BIN/trust-fail"
if run_incident recover >/dev/null 2>&1; then fail "untrusted Wi-Fi allowed incident recovery"; fi
[ -f "$JOURNAL" ] || fail "trust failure consumed the journal"
TEST_TRUST_CMD="$BIN/trust-ok"
TEST_VPN_CMD="$BIN/vpn-fail"
if run_incident recover >/dev/null 2>&1; then fail "unverified VPN allowed incident recovery"; fi
[ -f "$JOURNAL" ] || fail "VPN verification failure consumed the journal"

echo "4. verified recovery starts only incident-owned hashes and archives evidence"
TEST_VPN_CMD="$BIN/vpn-ok"
run_incident recover >/dev/null
[ ! -f "$JOURNAL" ] || fail "recovered journal remained active"
archive="$(find "$HOME_DIR/.local/state/darkmesh/transfer-incidents/history" -type f -name '*.json' -print -quit)"
[ -n "$archive" ] || fail "recovery evidence was not archived"
grep '/api/v2/items/start' "$REQUESTS" | grep -F "$A" | grep -F "$B" >/dev/null \
  || fail "targeted recovery did not start A and B"
! grep '/api/v2/items/start' "$REQUESTS" | grep -F "$C" >/dev/null \
  || fail "pre-paused C was started"
python3 - "$archive" "$A" "$B" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert data["status"] == "recovered"
assert data["active_hashes"] == [sys.argv[2], sys.argv[3]]
assert data["recovered_at"]
PY

echo "5. insecure or corrupt journals fail closed"
cp "$archive" "$JOURNAL"
python3 - "$JOURNAL" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path)); data["status"]="contained"
open(path,"w").write(json.dumps(data))
PY
chmod 644 "$JOURNAL"
if run_incident recover >/dev/null 2>&1; then fail "insecure journal was accepted"; fi
chmod 600 "$JOURNAL"
printf '{bad json\n' > "$JOURNAL"
if run_incident recover >/dev/null 2>&1; then fail "corrupt journal was accepted"; fi

echo "6. a live lock prevents concurrent mutation"
rm -f "$JOURNAL"
printf 'paused\n' > "$HOME_DIR/.config/darkmesh/transfer-desired"
run_incident contain operator-paused >/dev/null
[ ! -f "$JOURNAL" ] || fail "operator-paused state created automatic incident ownership"
printf 'active\n' > "$HOME_DIR/.config/darkmesh/transfer-desired"
mkdir -p "$HOME_DIR/.local/state/darkmesh/transfer-incidents/.lock"
printf '%s\n' "$$" > "$HOME_DIR/.local/state/darkmesh/transfer-incidents/.lock/pid"
if run_incident contain concurrent >/dev/null 2>&1; then fail "concurrent containment bypassed the lock"; fi

echo "7. explicit trust enrollment records only the current Wi-Fi identity"
rm -rf "$HOME_DIR/.local/state/darkmesh/transfer-incidents/.lock"
run_incident trust-current >/dev/null
TRUST_FILE="$HOME_DIR/.config/darkmesh/trusted-transfer-networks"
[ "$(cat "$TRUST_FILE")" = "00:11:22:33:44:55" ] || fail "trusted Wi-Fi identity was not recorded exactly"
[ "$(stat -f %Lp "$TRUST_FILE")" = 600 ] || fail "trusted-network file mode is not 0600"

echo "8. legacy stop and start aliases preserve the same exact ownership"
: > "$REQUESTS"
cat > "$STATE" <<EOF
[{"hash":"$A","state":"working"},{"hash":"$C","state":"stoppedDL"}]
EOF
TEST_MODERN_FAIL=1
run_incident contain legacy-api >/dev/null
run_incident recover >/dev/null
grep '/api/v2/items/pause' "$REQUESTS" | grep -F "$A" >/dev/null || fail "legacy stop alias was not targeted"
grep '/api/v2/items/resume' "$REQUESTS" | grep -F "$A" >/dev/null || fail "legacy start alias was not targeted"
! grep '/api/v2/items/resume' "$REQUESTS" | grep -F "$C" >/dev/null || fail "legacy recovery started pre-paused C"

echo "9. interruption after journaling is recoverable without losing ownership"
TEST_MODERN_FAIL=0; TEST_STOP_FAIL=1
cat > "$STATE" <<EOF
[{"hash":"$A","state":"working"}]
EOF
if run_incident contain interrupted >/dev/null 2>&1; then fail "failed targeted stop claimed containment success"; fi
[ -f "$JOURNAL" ] || fail "failed targeted stop lost the durable incident journal"
TEST_STOP_FAIL=0
run_incident contain interrupted-retry >/dev/null
python3 - "$JOURNAL" "$A" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))["active_hashes"] == [sys.argv[2]]
PY

echo "10. default recovery verification rejects a same-address stale interface"
printf '{"timestamp":"%s","max_age_seconds":60,"vpn_state":"Connected","internet_ok":true,"dns_ok":true}\n' \
  "$(date -u +%FT%TZ)" > "$HOME_DIR/status.json"
TEST_STOP_FAIL=0; TEST_VPN_CMD=""; TEST_BOUND_INTERFACE=utun5
if run_incident ready >/dev/null 2>&1; then fail "same-address stale interface passed recovery verification"; fi
TEST_BOUND_INTERFACE=utun8
run_incident ready >/dev/null || fail "matching interface and address did not pass recovery verification"

echo "PASS: incident-scoped transfer recovery tests"

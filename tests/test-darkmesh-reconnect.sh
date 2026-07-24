#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-reconnect-test)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; HOME_DIR="$TMP/home"
mkdir -p "$BIN" "$HOME_DIR/.config/darkmesh" "$HOME_DIR/Library/Logs/darkmesh"

stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "$body" > "$BIN/$name"
  chmod +x "$BIN/$name"
}

stub expressvpnctl '
printf "%s\n" "$*" >> "${TEST_CTL_LOG:?}"
if [[ "$*" == *"get connectionstate"* ]]; then echo Disconnected; fi
exit 0'
stub Tailscale 'exit 0'
stub curl '
out=""; headers=""; prev=""
for arg in "$@"; do
  [[ "$prev" == -o ]] && out="$arg"
  [[ "$prev" == -D ]] && headers="$arg"
  prev="$arg"
done
if [[ "$*" == *"captive.apple.com"* ]]; then
  [[ -n "$headers" ]] && : > "$headers"
  if [[ "${TEST_PORTAL:-0}" == 1 ]]; then [[ -n "$out" ]] && printf "Sign in" > "$out"; echo 302; exit 0; fi
  if [[ "${TEST_BLOCKED:-0}" == 1 ]]; then exit 28; fi
  [[ -n "$out" ]] && printf "Success" > "$out"
  echo 200; exit 0
fi
if [[ "$*" == *"gstatic.com/generate_204"* ]]; then
  [[ "${TEST_BLOCKED:-0}" == 1 ]] && exit 28
  echo 204; exit 0
fi
exit 1'
stub host 'exit 0'
stub route '
[[ "${TEST_ROUTE_MISSING:-0}" == 1 ]] && exit 1
echo "   gateway: 192.168.1.1"; echo " interface: en0"; exit 0'
stub ipconfig '
[[ "$1" == getifaddr ]] && { echo 192.168.1.20; exit 0; }
[[ "$1" == getpacket ]] && { echo "server_identifier (ip): {192.168.1.1}"; exit 0; }
exit 1'
stub plain-restore 'printf "%s\n" restore >> "${TEST_RESTORE_LOG:?}"; exit 0'
stub osascript 'printf "%s\n" "$*" >> "${TEST_ACTION_LOG:?}"; exit 0'
stub pkill 'printf "%s\n" "$*" >> "${TEST_ACTION_LOG:?}"; exit 0'
stub open 'printf "%s\n" "$*" >> "${TEST_ACTION_LOG:?}"; exit 0'
stub sleep 'exit 0'
stub security 'exit 1'

printf 'on\n' > "$HOME_DIR/.config/darkmesh/vpn-desired"
printf '%s\n' '{"schema":1,"action":"restart-wedged","reason":"dns-dead","requested_at":"2026-06-22T00:00:00Z"}' \
  > "$HOME_DIR/.config/darkmesh/reconnect-request.json"

HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_RECONNECT_REQUEST="$HOME_DIR/.config/darkmesh/reconnect-request.json" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$HOME_DIR/reconnect.pid" \
  DARKMESH_VPN_DESIRED="$HOME_DIR/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$HOME_DIR/status.json" DARKMESH_RECONNECT_SIDECAR="$HOME_DIR/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_OK=0 INTERVAL_RECOVER=0 MAX_APP_RESTARTS=1 \
  TEST_CTL_LOG="$HOME_DIR/ctl.log" TEST_ACTION_LOG="$HOME_DIR/action.log" \
  TEST_RESTORE_LOG="$HOME_DIR/restore.log" DARKMESH_CONNECT_OBSERVE=0 DARKMESH_APP_QUIT_WAIT=0 DARKMESH_APP_START_WAIT=0 DARKMESH_RESTRICTED_FIRST_DELAY=0 \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1

[[ ! -e "$HOME_DIR/.config/darkmesh/reconnect-request.json" ]] || { echo "request was not consumed" >&2; exit 1; }
grep -q 'quit app' "$HOME_DIR/action.log" || { echo "app restart was not serialized through reconnect" >&2; exit 1; }
grep -q 'restart-wedged result=issued' "$HOME_DIR/Library/Logs/darkmesh/actions.log" \
  || { echo "request result was not logged" >&2; exit 1; }

printf '%s\n' '{"schema":1,"action":"restart-wedged","reason":"dns-dead","requested_at":"2026-06-22T00:01:00Z"}' \
  > "$HOME_DIR/.config/darkmesh/reconnect-request.json"
HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_RECONNECT_REQUEST="$HOME_DIR/.config/darkmesh/reconnect-request.json" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$HOME_DIR/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$HOME_DIR/.config/darkmesh/reconnect-state" \
  DARKMESH_VPN_DESIRED="$HOME_DIR/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$HOME_DIR/status.json" DARKMESH_RECONNECT_SIDECAR="$HOME_DIR/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_OK=0 INTERVAL_RECOVER=0 MAX_APP_RESTARTS=1 \
  TEST_CTL_LOG="$HOME_DIR/ctl.log" TEST_ACTION_LOG="$HOME_DIR/action.log" \
  TEST_RESTORE_LOG="$HOME_DIR/restore.log" DARKMESH_CONNECT_OBSERVE=0 DARKMESH_APP_QUIT_WAIT=0 DARKMESH_APP_START_WAIT=0 DARKMESH_RESTRICTED_FIRST_DELAY=0 \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1

[[ "$(grep -c 'quit app' "$HOME_DIR/action.log")" == 1 ]] \
  || { echo "restart cap did not persist across process restart" >&2; exit 1; }
tail -1 "$HOME_DIR/Library/Logs/darkmesh/actions.log" | grep -q 'result=failed' \
  || { echo "persisted restart cap was not reported" >&2; exit 1; }

echo "PASS: reconnect serializes requests and persists its restart cap"

rm -f "$HOME_DIR/ctl.log" "$HOME_DIR/sidecar.json" "$HOME_DIR/.config/darkmesh/reconnect-state"

HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_RECONNECT_REQUEST="$HOME_DIR/.config/darkmesh/reconnect-request.json" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$HOME_DIR/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$HOME_DIR/.config/darkmesh/reconnect-state" \
  DARKMESH_VPN_DESIRED="$HOME_DIR/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$HOME_DIR/status.json" DARKMESH_RECONNECT_SIDECAR="$HOME_DIR/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_OK=0 INTERVAL_RECOVER=0 DARKMESH_CLEAR_TICKS_REQUIRED=3 \
  TEST_CTL_LOG="$HOME_DIR/ctl.log" TEST_ACTION_LOG="$HOME_DIR/action.log" \
  TEST_RESTORE_LOG="$HOME_DIR/restore.log" DARKMESH_CONNECT_OBSERVE=0 DARKMESH_RESTRICTED_FIRST_DELAY=0 \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1

! grep -q -- '--timeout 30 connect' "$HOME_DIR/ctl.log" \
  || { echo "reconnect did not wait for stable captive-clear probes" >&2; exit 1; }
grep -q '"phase": "captive-clear-wait"' "$HOME_DIR/sidecar.json" \
  || { echo "stable-clear wait phase was not reported" >&2; exit 1; }

echo "PASS: reconnect waits for stable captive-clear probes"

echo "PASS: reconnect baseline tests"

echo "1. positive captive evidence restores plain network and never connects"
PORTAL="$TMP/portal"; mkdir -p "$PORTAL/.config/darkmesh" "$PORTAL/Library/Logs/darkmesh"
printf 'on\n' > "$PORTAL/.config/darkmesh/vpn-desired"
HOME="$PORTAL" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$PORTAL/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$PORTAL/state" DARKMESH_VPN_DESIRED="$PORTAL/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$PORTAL/status.json" DARKMESH_RECONNECT_SIDECAR="$PORTAL/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_RECOVER=0 TEST_PORTAL=1 TEST_CTL_LOG="$PORTAL/ctl.log" \
  TEST_ACTION_LOG="$PORTAL/action.log" TEST_RESTORE_LOG="$PORTAL/restore.log" \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1
grep -q '"phase": "captive-standdown"' "$PORTAL/sidecar.json" || { echo "portal was not classified captive" >&2; exit 1; }
[[ ! -f "$PORTAL/ctl.log" ]] || ! grep -q -- '--timeout 30 connect' "$PORTAL/ctl.log" || { echo "VPN fought captive portal" >&2; exit 1; }
grep -q restore "$PORTAL/restore.log" || { echo "portal did not restore plain network" >&2; exit 1; }

echo "2. blocked global probes permit a bounded restricted-network VPN attempt"
REGION="$TMP/restricted"; mkdir -p "$REGION/.config/darkmesh" "$REGION/Library/Logs/darkmesh"
printf 'on\n' > "$REGION/.config/darkmesh/vpn-desired"
HOME="$REGION" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$REGION/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$REGION/state" DARKMESH_VPN_DESIRED="$REGION/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$REGION/status.json" DARKMESH_RECONNECT_SIDECAR="$REGION/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_RECOVER=0 DARKMESH_CONNECT_OBSERVE=0 DARKMESH_RESTRICTED_FIRST_DELAY=0 \
  DARKMESH_RESTRICTED_MIN_SPACING=0 TEST_BLOCKED=1 TEST_CTL_LOG="$REGION/ctl.log" \
  TEST_ACTION_LOG="$REGION/action.log" TEST_RESTORE_LOG="$REGION/restore.log" \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1
grep -q -- '--timeout 30 connect' "$REGION/ctl.log" || { echo "restricted network never attempted VPN" >&2; exit 1; }
grep -q '"plain_class": "restricted"' "$REGION/sidecar.json" || { echo "restricted class missing" >&2; exit 1; }

echo "PASS: captive and restricted-network reconnect tests"

echo "3. signal storms cannot shorten an absolute retry deadline"
STORM="$TMP/storm"; mkdir -p "$STORM/.config/darkmesh" "$STORM/Library/Logs/darkmesh"
printf 'on\n' > "$STORM/.config/darkmesh/vpn-desired"
HOME="$STORM" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$STORM/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$STORM/state" DARKMESH_VPN_DESIRED="$STORM/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$STORM/status.json" DARKMESH_RECONNECT_SIDECAR="$STORM/sidecar.json" \
  DARKMESH_MAX_TICKS=2 INTERVAL_RECOVER=2 MAX_BACKOFF=2 DARKMESH_CONNECT_OBSERVE=0 \
  DARKMESH_RESTRICTED_FIRST_DELAY=0 DARKMESH_RESTRICTED_MIN_SPACING=2 DARKMESH_NETWORK_DEBOUNCE=0 \
  TEST_BLOCKED=1 TEST_CTL_LOG="$STORM/ctl.log" TEST_ACTION_LOG="$STORM/action.log" \
  TEST_RESTORE_LOG="$STORM/restore.log" \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1 &
storm_job=$!
for _ in {1..100}; do
  grep -q -- '--timeout 30 connect' "$STORM/ctl.log" 2>/dev/null && break
  /bin/sleep 0.02
done
storm_pid="$(cat "$STORM/reconnect.pid")"
for _ in {1..20}; do kill -USR1 "$storm_pid" 2>/dev/null || true; done
/bin/sleep 1
[[ "$(grep -c -- '--timeout 30 connect' "$STORM/ctl.log")" == 1 ]] \
  || { echo "signals bypassed reconnect backoff" >&2; kill "$storm_job" 2>/dev/null || true; exit 1; }
wait "$storm_job"
[[ "$(grep -c -- '--timeout 30 connect' "$STORM/ctl.log")" == 2 ]] \
  || { echo "scheduled retry did not occur after deadline" >&2; exit 1; }

echo "PASS: reconnect signal deadline test"

echo "4. an in-progress connection is observed instead of torn down"
stub progressing-expressvpnctl '
printf "%s\n" "$*" >> "${TEST_CTL_LOG:?}"
state_file="${TEST_STATE_FILE:?}"
if [[ "$*" == *"get connectionstate"* ]]; then
  if [[ -f "$state_file" ]]; then
    count="$(cat "$state_file")"; count=$((count + 1)); printf "%s\n" "$count" > "$state_file"
    if (( count < 3 )); then echo Connecting; else echo Connected; fi
  else
    echo Disconnected
  fi
elif [[ "$*" == *"connect"* ]]; then
  printf "0\n" > "$state_file"
fi
exit 0'
PROGRESS="$TMP/progress"; mkdir -p "$PROGRESS/.config/darkmesh" "$PROGRESS/Library/Logs/darkmesh"
printf 'on\n' > "$PROGRESS/.config/darkmesh/vpn-desired"
HOME="$PROGRESS" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CTL="$BIN/progressing-expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$PROGRESS/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$PROGRESS/state" DARKMESH_VPN_DESIRED="$PROGRESS/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$PROGRESS/status.json" DARKMESH_RECONNECT_SIDECAR="$PROGRESS/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_RECOVER=0 DARKMESH_CLEAR_TICKS_REQUIRED=1 DARKMESH_CONNECT_OBSERVE=5 \
  TEST_CTL_LOG="$PROGRESS/ctl.log" TEST_ACTION_LOG="$PROGRESS/action.log" \
  TEST_RESTORE_LOG="$PROGRESS/restore.log" TEST_STATE_FILE="$PROGRESS/vpn-state" \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1
grep -q '"phase": "reconnected"' "$PROGRESS/sidecar.json" || { echo "progressing connection was treated as failure" >&2; exit 1; }
[[ ! -e "$PROGRESS/restore.log" ]] || { echo "plain restore interrupted a progressing connection" >&2; exit 1; }

echo "PASS: progressing VPN connection test"

echo "5. a transient missing default route cannot reset the recovery budget"
NO_ROUTE="$TMP/no-route"; mkdir -p "$NO_ROUTE/.config/darkmesh" "$NO_ROUTE/Library/Logs/darkmesh"
printf 'on\n' > "$NO_ROUTE/.config/darkmesh/vpn-desired"
{
  printf '%s\n' 'last_network_key=en0|192.168.1.1|192.168.1.20|192.168.1.1'
  printf 'network_started_at=%s\n' "$(date +%s)"
  printf 'restricted_window_started=%s\n' "$(date +%s)"
  printf '%s\n' 'restricted_attempts=2' 'next_attempt_at=0'
} > "$NO_ROUTE/state"
HOME="$NO_ROUTE" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" CTL="$BIN/expressvpnctl" TS="$BIN/Tailscale" \
  DARKMESH_PLAIN_RESTORE="$BIN/plain-restore" DARKMESH_RECONNECT_PID_FILE="$NO_ROUTE/reconnect.pid" \
  DARKMESH_RECONNECT_STATE="$NO_ROUTE/state" DARKMESH_VPN_DESIRED="$NO_ROUTE/.config/darkmesh/vpn-desired" \
  DARKMESH_STATUS_FILE="$NO_ROUTE/status.json" DARKMESH_RECONNECT_SIDECAR="$NO_ROUTE/sidecar.json" \
  DARKMESH_MAX_TICKS=1 INTERVAL_RECOVER=0 TEST_ROUTE_MISSING=1 TEST_BLOCKED=1 \
  TEST_CTL_LOG="$NO_ROUTE/ctl.log" TEST_ACTION_LOG="$NO_ROUTE/action.log" \
  TEST_RESTORE_LOG="$NO_ROUTE/restore.log" \
  bash "$ROOT/scripts/darkmesh-reconnect" >/dev/null 2>&1
! grep -q 'physical network changed' "$NO_ROUTE/Library/Logs/darkmesh/reconnect.log" \
  || { echo "missing route reset the recovery budget" >&2; exit 1; }
grep -q '^restricted_attempts=2$' "$NO_ROUTE/state" \
  || { echo "missing route cleared the restricted-attempt budget" >&2; exit 1; }

echo "PASS: incomplete fingerprints preserve the recovery budget"

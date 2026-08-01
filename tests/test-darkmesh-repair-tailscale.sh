#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-tailscale-repair-test)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "$body" >"$BIN/$name"
  chmod +x "$BIN/$name"
}

stub Tailscale '
case "$1" in
  status)
    [[ "${TEST_TS_HANG:-0}" == 1 ]] && { kill -STOP $$; sleep 300; }
    echo "{\"BackendState\":\"Running\",\"Self\":{\"Online\":true}}"
    ;;
  ip) echo "100.68.156.16" ;;
  debug)
    if [[ "${TEST_PREFS_CHANGE:-0}" == 1 && -f "${TEST_REPAIRED:?}" ]]; then
      echo "{\"WantRunning\":false}"
    else
      echo "{\"WantRunning\":${TEST_WANT_RUNNING:-true},\"CorpDNS\":false}"
    fi
    ;;
esac'

stub route '
if [[ "$*" == *" default"* ]]; then
  echo " interface: ${TEST_DEFAULT_INTERFACE:-en0}"
  exit 0
fi
if [[ "$*" == *"100.68.156.16"* ]]; then
  if [[ -f "${TEST_REPAIRED:?}" ]]; then echo " interface: utun9"; else echo " interface: ${TEST_SELF_INTERFACE:-utun9}"; fi
  exit 0
fi
if [[ "${TEST_ROUTE_STALE:-0}" == 1 && ! -f "${TEST_REPAIRED:?}" ]]; then
  echo " interface: en0"
else
  echo " interface: utun9"
fi'

stub scutil '
printf "%s\n" "$*" >>"${TEST_ACTIONS:?}"
case "$*" in
  "--nc status Tailscale")
    [[ "${TEST_NEVER_DISCONNECT:-0}" != 1 && -f "${TEST_STOPPED:?}" ]] && echo Disconnected || echo Connected
    ;;
  "--nc stop Tailscale") : >"${TEST_STOPPED:?}" ;;
  "--nc start Tailscale")
    if [[ "${TEST_START_FAIL_ONCE:-0}" == 1 && ! -f "${TEST_START_FAILED:?}" ]]; then
      : >"${TEST_START_FAILED:?}"
      exit 1
    fi
    rm -f "${TEST_STOPPED:?}"; : >"${TEST_REPAIRED:?}"
    ;;
esac'

stub expressvpnctl '
[[ "${TEST_VPN_CONNECTED:-0}" == 1 ]] && echo Connected || echo Disconnected'
stub open 'exit 0'
stub sleep 'exit 0'

run_repair() {
  local home="$1"; shift
  mkdir -p "$home/.config/darkmesh"
  HOME="$home" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TAILSCALE_CLI="$BIN/Tailscale" DARKMESH_ROUTE="$BIN/route" \
    DARKMESH_SCUTIL="$BIN/scutil" DARKMESH_OPEN="$BIN/open" \
    EXPRESSVPN_CTL="$BIN/expressvpnctl" \
    DARKMESH_TAILSCALE_REPAIR_STATE="$home/.config/darkmesh/tailscale-repair-at" \
    DARKMESH_TAILSCALE_REPAIR_LOCK="$home/.config/darkmesh/tailscale-repair.lock" \
    DARKMESH_TAILSCALE_FAIL_SAMPLES=2 DARKMESH_TAILSCALE_SAMPLE_INTERVAL=0 \
    DARKMESH_TAILSCALE_STOP_TIMEOUT=2 DARKMESH_TAILSCALE_START_TIMEOUT=2 \
    TEST_ACTIONS="$home/actions" TEST_STOPPED="$home/stopped" TEST_REPAIRED="$home/repaired" \
    TEST_START_FAILED="$home/start-failed" \
    "$@"
}

echo "1. a healthy Tailscale route is mutation-free"
HEALTHY="$TMP/healthy"
TEST_ROUTE_STALE=0 run_repair "$HEALTHY" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null
[[ ! -e "$HEALTHY/actions" ]] || { echo "healthy route mutated VPN service" >&2; exit 1; }

echo "2. a stable missing route restarts only the saved VPN service"
STALE="$TMP/stale"
TEST_ROUTE_STALE=1 run_repair "$STALE" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null
grep -q '^--nc stop Tailscale$' "$STALE/actions" || { echo "stale service was not stopped" >&2; exit 1; }
grep -q '^--nc start Tailscale$' "$STALE/actions" || { echo "stale service was not started" >&2; exit 1; }

echo "3. a connected ExpressVPN tunnel blocks Tailscale mutation"
CONNECTED="$TMP/connected"
set +e
TEST_ROUTE_STALE=1 TEST_VPN_CONNECTED=1 run_repair "$CONNECTED" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 3 ]] || { echo "connected VPN returned $rc, expected 3" >&2; exit 1; }
[[ ! -e "$CONNECTED/actions" ]] || { echo "connected VPN allowed Tailscale mutation" >&2; exit 1; }

echo "4. preference drift makes repair verification fail"
DRIFT="$TMP/drift"
set +e
TEST_ROUTE_STALE=1 TEST_PREFS_CHANGE=1 run_repair "$DRIFT" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 1 ]] || { echo "preference drift returned $rc, expected 1" >&2; exit 1; }

echo "5. automatic repair obeys its cooldown"
COOLDOWN="$TMP/cooldown"
mkdir -p "$COOLDOWN/.config/darkmesh"
: >"$COOLDOWN/.config/darkmesh/tailscale-repair-at"
TEST_ROUTE_STALE=1 run_repair "$COOLDOWN" bash "$ROOT/scripts/darkmesh-repair-tailscale" --auto >/dev/null
[[ ! -e "$COOLDOWN/actions" ]] || { echo "automatic cooldown allowed another restart" >&2; exit 1; }

echo "6. automatic repair respects an intentionally stopped tailnet"
STOPPED="$TMP/intentionally-stopped"
TEST_ROUTE_STALE=1 TEST_WANT_RUNNING=false run_repair "$STOPPED" bash "$ROOT/scripts/darkmesh-repair-tailscale" --auto >/dev/null
[[ ! -e "$STOPPED/actions" ]] || { echo "intentionally stopped tailnet was restarted" >&2; exit 1; }

echo "7. a different utun owner is not accepted as Tailscale"
WRONG_UTUN="$TMP/wrong-utun"
TEST_ROUTE_STALE=0 TEST_SELF_INTERFACE=utun8 run_repair "$WRONG_UTUN" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null
grep -q '^--nc stop Tailscale$' "$WRONG_UTUN/actions" || { echo "wrong utun owner was accepted" >&2; exit 1; }

echo "8. a failed start gets one best-effort rollback start"
ROLLBACK="$TMP/rollback"
set +e
TEST_ROUTE_STALE=1 TEST_START_FAIL_ONCE=1 run_repair "$ROLLBACK" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 1 ]] || { echo "failed start returned $rc, expected 1" >&2; exit 1; }
[[ "$(grep -c '^--nc start Tailscale$' "$ROLLBACK/actions")" == 2 ]] \
  || { echo "failed start did not get one rollback attempt" >&2; exit 1; }
[[ ! -e "$ROLLBACK/stopped" ]] || { echo "rollback left the service stopped" >&2; exit 1; }

echo "9. concurrent repairs cannot interleave"
LOCKED="$TMP/locked"
mkdir -p "$LOCKED/.config/darkmesh/tailscale-repair.lock"
printf '%s\n' "$$" >"$LOCKED/.config/darkmesh/tailscale-repair.lock/pid"
set +e
TEST_ROUTE_STALE=1 run_repair "$LOCKED" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 75 ]] || { echo "concurrent repair returned $rc, expected 75" >&2; exit 1; }
[[ ! -e "$LOCKED/actions" ]] || { echo "concurrent repair mutated the service" >&2; exit 1; }

echo "10. a hung Tailscale CLI is bounded"
HUNG="$TMP/hung"
started="$(date +%s)"
set +e
TEST_TS_HANG=1 DARKMESH_TAILSCALE_CLI_TIMEOUT=1 run_repair "$HUNG" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null 2>&1
rc=$?
set -e
elapsed=$(( $(date +%s) - started ))
[[ "$rc" -ne 0 && "$elapsed" -le 10 ]] || { echo "hung CLI rc=$rc elapsed=${elapsed}s" >&2; exit 1; }

echo "11. a missing disconnected transition still forces a verified start"
NO_TRANSITION="$TMP/no-transition"
TEST_ROUTE_STALE=1 TEST_NEVER_DISCONNECT=1 run_repair "$NO_TRANSITION" bash "$ROOT/scripts/darkmesh-repair-tailscale" >/dev/null 2>&1
grep -q '^--nc start Tailscale$' "$NO_TRANSITION/actions" \
  || { echo "missing disconnect transition prevented restart" >&2; exit 1; }

echo "PASS: bounded Tailscale service repair tests"

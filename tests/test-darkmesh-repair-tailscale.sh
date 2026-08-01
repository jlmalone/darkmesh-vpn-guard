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
  status) echo "{\"BackendState\":\"Running\",\"Self\":{\"Online\":true}}" ;;
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
if [[ "${TEST_ROUTE_STALE:-0}" == 1 && ! -f "${TEST_REPAIRED:?}" ]]; then
  echo " interface: en0"
else
  echo " interface: utun9"
fi'

stub scutil '
printf "%s\n" "$*" >>"${TEST_ACTIONS:?}"
case "$*" in
  "--nc status Tailscale")
    [[ -f "${TEST_STOPPED:?}" ]] && echo Disconnected || echo Connected
    ;;
  "--nc stop Tailscale") : >"${TEST_STOPPED:?}" ;;
  "--nc start Tailscale") rm -f "${TEST_STOPPED:?}"; : >"${TEST_REPAIRED:?}" ;;
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
    DARKMESH_TAILSCALE_FAIL_SAMPLES=2 DARKMESH_TAILSCALE_SAMPLE_INTERVAL=0 \
    DARKMESH_TAILSCALE_STOP_TIMEOUT=2 DARKMESH_TAILSCALE_START_TIMEOUT=2 \
    TEST_ACTIONS="$home/actions" TEST_STOPPED="$home/stopped" TEST_REPAIRED="$home/repaired" \
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

echo "PASS: bounded Tailscale service repair tests"

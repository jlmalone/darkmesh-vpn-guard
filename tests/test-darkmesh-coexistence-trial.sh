#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

make_stub() {
  local name="$1"
  shift
  {
    printf '#!/bin/bash\n'
    printf '%s\n' "$*"
  } >"$BIN/$name"
  chmod +x "$BIN/$name"
}

make_stub expressvpnctl '
printf "ctl %s\n" "$*" >>"${TEST_CALLS:?}"
case "$*" in
  *"get connectionstate"*)
    if [[ "$(grep "^darkmesh " "${TEST_CALLS:?}" | tail -1)" == "darkmesh panic" ]]; then
      printf "Disconnected\n"
    else
      printf "Connected\n"
    fi
    ;;
  *"get protocol"*) printf "lightwaytcp\n" ;;
  *"get splittunnel"*) printf "true\n" ;;
  *"get split-app"*) printf "bypass:/Applications/Tailscale.app/Contents/MacOS/Tailscale\nbypass:/Library/SystemExtensions/example/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension\n" ;;
esac
'
make_stub tailscale '
printf "tailscale %s\n" "$*" >>"${TEST_CALLS:?}"
if [[ "${TEST_FAIL_TAILSCALE_WITH_VPN:-no}" == yes && "$1" == ping ]] \
  && [[ "$(grep "^darkmesh " "${TEST_CALLS:?}" | tail -1)" == "darkmesh up" ]]; then
  exit 1
fi
exit 0
'
make_stub darkmesh '
printf "darkmesh %s\n" "$*" >>"${TEST_CALLS:?}"
exit 0
'
make_stub curl 'exit 0'
make_stub host 'exit 0'
make_stub open 'printf "open %s\n" "$*" >>"${TEST_CALLS:?}"'
make_stub osascript 'printf "osascript %s\n" "$*" >>"${TEST_CALLS:?}"'
make_stub ssh 'printf "ssh %s\n" "$*" >>"${TEST_CALLS:?}"'
make_stub sleep 'exit 0'

run_trial() {
  local case_dir="$1"
  shift
  mkdir -p "$case_dir"
  TEST_CALLS="$case_dir/calls" \
  EXPRESSVPN_CTL="$BIN/expressvpnctl" TAILSCALE_CLI="$BIN/tailscale" \
  DARKMESH_CLI="$BIN/darkmesh" CURL="$BIN/curl" HOST="$BIN/host" \
  OPEN_CMD="$BIN/open" OSASCRIPT="$BIN/osascript" SSH="$BIN/ssh" SLEEP="$BIN/sleep" \
  DARKMESH_TRIAL_LOG="$case_dir/log" DARKMESH_TRIAL_RESULT="$case_dir/result" \
  DARKMESH_TRIAL_LOCK="$case_dir/lock" DARKMESH_TRIAL_DISABLE_DEADMAN=yes \
  DARKMESH_TRIAL_CONNECT_TIMEOUT=2 DARKMESH_TRIAL_SETTLE_SECONDS=0 \
  "$@" "$ROOT/scripts/darkmesh-coexistence-trial" --peer peer.example --ssh-target peer-alias
}

SUCCESS="$TMP/success"
run_trial "$SUCCESS" env
grep -q 'PASS: Lightway TCP' "$SUCCESS/log"
grep -q 'finished; experiment_rc=0; internet=yes; dns=yes; tailscale_peer=yes; vpn=off' "$SUCCESS/result"
[[ "$(grep -c '^darkmesh panic$' "$SUCCESS/calls")" -eq 2 ]]
[[ "$(tail -1 "$SUCCESS/calls")" == "tailscale ping --c 1 peer.example" ]]
grep -q '^ctl --timeout 8 background disable$' "$SUCCESS/calls"
grep -q '^ctl --timeout 8 set protocol lightwaytcp$' "$SUCCESS/calls"
grep -q '^ssh -o BatchMode=yes -o ConnectTimeout=10 peer-alias nice -n 19 true$' "$SUCCESS/calls"

FAILURE="$TMP/failure"
if run_trial "$FAILURE" env TEST_FAIL_TAILSCALE_WITH_VPN=yes; then
  echo "expected coexistence failure" >&2
  exit 1
fi
grep -q 'FAIL: the Tailscale peer failed with Lightway connected' "$FAILURE/log"
grep -q 'finished; experiment_rc=1; internet=yes; dns=yes; tailscale_peer=yes; vpn=off' "$FAILURE/result"
[[ "$(grep -c '^darkmesh panic$' "$FAILURE/calls")" -eq 2 ]]
grep -q '^tailscale up$' "$FAILURE/calls"

echo "darkmesh coexistence trial tests passed"

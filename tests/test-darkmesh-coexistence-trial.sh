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
    elif [[ "${TEST_VPN_NEVER_CONNECTS:-no}" == yes ]]; then
      printf "Connecting\n"
    else
      printf "Connected\n"
    fi
    ;;
  *"get protocol"*) printf "lightwaytcp\n" ;;
  *"get region"*) cat "${TEST_REGION_STATE:?}" ;;
  *"set region "*)
    printf "%s\n" "${!#}" >"${TEST_REGION_STATE:?}"
    ;;
  *"get splittunnel"*) printf "true\n" ;;
  *"get split-app"*) cat "${TEST_SPLIT_STATE:?}" ;;
  *"set split-app remove:"*)
    : >"${TEST_SPLIT_STATE:?}"
    ;;
  *"set split-app bypass:"*)
    entry="${!#}"
    grep -qxF "$entry" "${TEST_SPLIT_STATE:?}" || printf "%s\n" "$entry" >>"${TEST_SPLIT_STATE:?}"
    ;;
esac
'
make_stub tailscale '
printf "tailscale %s\n" "$*" >>"${TEST_CALLS:?}"
if [[ "${TEST_FAIL_TAILSCALE_WITH_VPN:-no}" == yes && "$1" == ping ]] \
  && [[ "$(grep "^darkmesh " "${TEST_CALLS:?}" | tail -1)" == "darkmesh up" ]]; then
  exit 1
fi
if [[ -n "${TEST_TAILSCALE_RECOVER_AFTER:-}" && "$1" == ping ]] \
  && [[ "$(grep "^darkmesh " "${TEST_CALLS:?}" | tail -1)" == "darkmesh up" ]]; then
  count=0
  [[ -r "${TEST_CALLS}.ping-count" ]] && count="$(cat "${TEST_CALLS}.ping-count")"
  count=$((count + 1))
  printf "%s\n" "$count" >"${TEST_CALLS}.ping-count"
  ((count > TEST_TAILSCALE_RECOVER_AFTER)) || exit 1
fi
if [[ "${TEST_DERP_PONG_NONZERO:-no}" == yes && "$1" == ping ]]; then
  printf "pong from peer.example via DERP(example) in 12ms\n"
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
  local trial_mode="$2"
  local trial_protocol="$3"
  local trial_region="$4"
  shift 4
  mkdir -p "$case_dir"
  printf "bypass:/Applications/Tailscale.app/Contents/MacOS/Tailscale\nbypass:/Library/SystemExtensions/example/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension\n" >"$case_dir/split-state"
  printf "usa-seattle\n" >"$case_dir/region-state"
  TEST_CALLS="$case_dir/calls" \
  TEST_SPLIT_STATE="$case_dir/split-state" \
  TEST_REGION_STATE="$case_dir/region-state" \
  EXPRESSVPN_CTL="$BIN/expressvpnctl" TAILSCALE_CLI="$BIN/tailscale" \
  DARKMESH_CLI="$BIN/darkmesh" CURL="$BIN/curl" HOST="$BIN/host" \
  OPEN_CMD="$BIN/open" OSASCRIPT="$BIN/osascript" SSH="$BIN/ssh" SLEEP="$BIN/sleep" \
  DARKMESH_TRIAL_LOG="$case_dir/log" DARKMESH_TRIAL_RESULT="$case_dir/result" \
  DARKMESH_TRIAL_LOCK="$case_dir/lock" DARKMESH_TRIAL_DISABLE_DEADMAN=yes \
  DARKMESH_TRIAL_CONNECT_TIMEOUT=2 DARKMESH_TRIAL_SETTLE_SECONDS=0 \
  DARKMESH_TRIAL_TAILSCALE_TIMEOUT=10 DARKMESH_TRIAL_PROBE_INTERVAL=5 \
  "$@" "$ROOT/scripts/darkmesh-coexistence-trial" --mode "$trial_mode" \
    --protocol "$trial_protocol" \
    --region "$trial_region" \
    --peer peer.example --ssh-target peer-alias
}

SUCCESS="$TMP/success"
run_trial "$SUCCESS" bypass lightwaytcp current env
grep -q 'PASS: protocol=lightwaytcp' "$SUCCESS/log"
grep -q 'finished; experiment_rc=0; internet=yes; dns=yes; tailscale_peer=yes; vpn=off; split_rules_restored=yes' "$SUCCESS/result"
[[ "$(grep -c '^darkmesh panic$' "$SUCCESS/calls")" -eq 2 ]]
[[ "$(tail -1 "$SUCCESS/calls")" == "tailscale ping --c 1 peer.example" ]]
grep -q '^ctl --timeout 8 background disable$' "$SUCCESS/calls"
grep -q '^ctl --timeout 8 set protocol lightwaytcp$' "$SUCCESS/calls"
grep -q '^ssh -o BatchMode=yes -o ConnectTimeout=10 peer-alias nice -n 19 true$' "$SUCCESS/calls"

DERP="$TMP/derp"
run_trial "$DERP" bypass lightwaytcp current env TEST_DERP_PONG_NONZERO=yes
grep -q 'finished; experiment_rc=0; internet=yes; dns=yes; tailscale_peer=yes; vpn=off; split_rules_restored=yes' "$DERP/result"

FAILURE="$TMP/failure"
if run_trial "$FAILURE" bypass lightwaytcp current env TEST_FAIL_TAILSCALE_WITH_VPN=yes; then
  echo "expected coexistence failure" >&2
  exit 1
fi
grep -q 'FAIL: the Tailscale peer did not converge within the 10s observation window' "$FAILURE/log"
grep -q 'DIAGNOSIS: the configured ExpressVPN bypass did not preserve Tailscale with protocol=lightwaytcp' "$FAILURE/log"
grep -q 'finished; experiment_rc=1; internet=yes; dns=yes; tailscale_peer=yes; vpn=off; split_rules_restored=yes' "$FAILURE/result"
[[ "$(grep -c '^darkmesh panic$' "$FAILURE/calls")" -eq 2 ]]
grep -q '^tailscale up$' "$FAILURE/calls"

DELAYED="$TMP/delayed"
run_trial "$DELAYED" bypass lightwaytcp current env TEST_TAILSCALE_RECOVER_AFTER=2
grep -q 'Tailscale peer converged after .*s of observation' "$DELAYED/log"
grep -q 'finished; experiment_rc=0; internet=yes; dns=yes' "$DELAYED/result"

DEADMAN="$TMP/deadman"
mkdir -p "$DEADMAN"
if ! run_trial "$DEADMAN" bypass lightwaytcp current env DARKMESH_TRIAL_DISABLE_DEADMAN=no \
  DEADMAN_SLEEP=/bin/sleep DARKMESH_TRIAL_DEADMAN_SECONDS=30 \
  >"$DEADMAN/stdout" 2>"$DEADMAN/stderr"; then
  echo "expected deadman-cancellation run to pass" >&2
  exit 1
fi
! grep -q 'Terminated' "$DEADMAN/stderr"

THROUGH="$TMP/through"
run_trial "$THROUGH" through-vpn lightwaytcp current env
grep -q 'PASS: protocol=lightwaytcp.*mode=through-vpn' "$THROUGH/log"
[[ "$(grep -c 'set split-app remove:' "$THROUGH/calls")" -eq 2 ]]
grep -q 'bypass:/Applications/Tailscale.app/Contents/MacOS/Tailscale' "$THROUGH/split-state"
grep -q 'bypass:.*io.tailscale.ipn.macsys.network-extension' "$THROUGH/split-state"

UDP="$TMP/udp"
run_trial "$UDP" bypass lightwayudp current env
grep -q 'set protocol lightwayudp' "$UDP/calls"
grep -q 'PASS: protocol=lightwayudp' "$UDP/log"

NO_CONNECT="$TMP/no-connect"
if run_trial "$NO_CONNECT" bypass lightwayudp current env TEST_VPN_NEVER_CONNECTS=yes; then
  echo "expected VPN connection timeout" >&2
  exit 1
fi
grep -q 'did not connect (state=Connecting protocol=lightwayudp region=usa-seattle)' "$NO_CONNECT/log"
grep -q 'finished; experiment_rc=1; internet=yes; dns=yes' "$NO_CONNECT/result"

REGION="$TMP/region"
run_trial "$REGION" bypass lightwaytcp canada-vancouver env
grep -q 'selected region=canada-vancouver (original=usa-seattle)' "$REGION/log"
[[ "$(cat "$REGION/region-state")" == "usa-seattle" ]]
grep -q 'region_restored=yes' "$REGION/result"

echo "darkmesh coexistence trial tests passed"

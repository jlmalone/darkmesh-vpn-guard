#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-experiment-tests)"
trap '[[ "${KEEP_DARKMESH_TEST_TMP:-no}" == yes ]] || rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"
STUB="$ROOT/tests/fixtures/darkmesh-experiment-command-stub"
for name in expressvpnctl tailscale darkmesh darkmesh-transfer vpn-guard.sh \
  transfer-vpn-doctor curl host ssh nc systemextensionsctl scutil netstat \
  ifconfig ipconfig pfctl sudo pgrep defaults date sleep nettop tcpdump; do
  ln -s "$STUB" "$BIN/$name"
done

fail() { echo "FAIL: $*" >&2; exit 1; }

new_fixture() {
  local name="$1" dir
  dir="$TMP/$name"
  mkdir -p "$dir/state" "$dir/runs"
  printf 'Disconnected\n' >"$dir/state/vpn-state"
  printf 'lightwaytcp\n' >"$dir/state/protocol"
  printf 'usa-seattle\n' >"$dir/state/region"
  printf 'true\n' >"$dir/state/splittunnel"
  printf 'false\n' >"$dir/state/networklock"
  printf 'false\n' >"$dir/state/autoconnect"
  printf 'false\n' >"$dir/state/accept-dns"
  printf 'node-original\n' >"$dir/state/identity"
  printf 'Running\n' >"$dir/state/tailscale-state"
  printf 'off\n' >"$dir/state/vpn-intent"
  printf 'paused\n' >"$dir/state/transfer-intent"
  cat >"$dir/state/split-rules" <<'EOF'
bypass:/Applications/Remote.app/Contents/MacOS/remote
bypass:/Applications/Tailscale.app/Contents/MacOS/Tailscale
bypass:/Library/SystemExtensions/example/io.tailscale.ipn.macsys.network-extension.systemextension/Contents/MacOS/io.tailscale.ipn.macsys.network-extension
EOF
  cat >"$dir/config" <<'EOF'
PEER_A_ADDRESS=peer-a.example
PEER_A_SSH=host-a
PEER_B_ADDRESS=peer-b.example
PEER_B_SSH=host-b
SEATTLE_REGION=usa-seattle
NEARBY_REGION=canada-vancouver
EOF
  chmod 600 "$dir/config"
  printf '%s\n' "$dir"
}

run_experiment() {
  local fixture="$1"
  shift
  TEST_STATE="$fixture/state" \
  EXPRESSVPN_CTL="$BIN/expressvpnctl" TAILSCALE_CLI="$BIN/tailscale" \
  DARKMESH_CLI="$BIN/darkmesh" DARKMESH_TRANSFER="$BIN/darkmesh-transfer" \
  VPN_GUARD="$BIN/vpn-guard.sh" TRANSFER_DOCTOR="$BIN/transfer-vpn-doctor" \
  CURL="$BIN/curl" HOST_CMD="$BIN/host" SSH_CMD="$BIN/ssh" NC_CMD="$BIN/nc" \
  SYSTEMEXTENSIONSCTL="$BIN/systemextensionsctl" SCUTIL="$BIN/scutil" \
  NETSTAT="$BIN/netstat" IFCONFIG="$BIN/ifconfig" PFCTL="$BIN/pfctl" \
  IPCONFIG="$BIN/ipconfig" \
  SUDO="$BIN/sudo" PGREP="$BIN/pgrep" DEFAULTS="$BIN/defaults" \
  DATE="$BIN/date" SLEEP="$BIN/sleep" NETTOP="$BIN/nettop" TCPDUMP="$BIN/tcpdump" \
  DARKMESH_EXPERIMENT_CONFIG="$fixture/config" \
  DARKMESH_EXPERIMENT_ROOT="$fixture/runs" \
  DARKMESH_EXPERIMENT_LOCK="$fixture/lock" \
  DARKMESH_VPN_INTENT="$fixture/state/vpn-intent" \
  DARKMESH_TRANSFER_INTENT="$fixture/state/transfer-intent" \
  DARKMESH_EXPERIMENT_BASELINE_QUIET=0 \
  DARKMESH_EXPERIMENT_STABILIZE_MIN=0 \
  DARKMESH_EXPERIMENT_RECOVERY_QUIET=0 \
  DARKMESH_EXPERIMENT_SAMPLE_INTERVAL=1 \
  DARKMESH_EXPERIMENT_DISABLE_DEADMAN=yes \
  "$@"
}

echo "1. mutation-free plan covers every staged matrix dimension"
plan="$("$ROOT/scripts/darkmesh-experiment" plan --profile staged --format json)"
PLAN="$plan" /usr/bin/python3 <<'PY'
import json,os
d=json.loads(os.environ["PLAN"])
text="\n".join(row["phase"]+" "+row["case"] for row in d["cases"])
for value in ("wireguard","lightwaytcp","lightwayudp","dns-on","smart",
              "nearby","extension-only","app-only","neither","disabled",
              "vpn-first","tailscale-restart","repeatability",
              "reconnect-state-machine","ordinary-disconnect-recovery"):
    assert value in text, value
assert d["mutationFree"] is True
PY

echo "2. preflight accepts a complete read-only fixture"
preflight="$(new_fixture preflight)"
run_experiment "$preflight" env "$ROOT/scripts/darkmesh-experiment" preflight >"$preflight/out"
grep -q $'peer-a.ssh\tPASS' "$preflight/out"
grep -q $'containment.pf\tPASS' "$preflight/out"
! grep -q '^darkmesh-transfer ' "$preflight/state/calls"
! grep -q '^darkmesh up' "$preflight/state/calls"

echo "3. privilege failure is PRECONDITION, not a protocol failure"
privilege="$(new_fixture privilege)"
if run_experiment "$privilege" env TEST_PRIVILEGE_FAILURE=yes \
  "$ROOT/scripts/darkmesh-experiment" preflight >"$privilege/out"; then
  fail "privilege precondition unexpectedly passed"
fi
grep -q $'containment.pf\tPRECONDITION' "$privilege/out"

echo "3b. fresh enforced PF sidecar satisfies the installed privilege contract"
sidecar="$(new_fixture sidecar)"
sidecar_file="$sidecar/state/pf.json"
cat >"$sidecar_file" <<EOF
{
  "pf_enabled": true,
  "pf_anchor": "com.apple/vpn-guard",
  "pf_anchor_evaluated": true,
  "pf_kill_active": true,
  "checked_at": "$(/bin/date -u +%FT%TZ)"
}
EOF
run_experiment "$sidecar" env TEST_PF_RULE_READ_FAILURE=yes \
  DARKMESH_PF_SIDECAR="$sidecar_file" \
  "$ROOT/scripts/darkmesh-experiment" preflight >"$sidecar/out"
grep -q $'containment.pf\tPASS' "$sidecar/out"

echo "4. active transfer intent is rejected before any campaign mutation"
intent="$(new_fixture intent)"
printf 'active\n' >"$intent/state/transfer-intent"
if run_experiment "$intent" env "$ROOT/scripts/darkmesh-experiment" preflight >"$intent/out"; then
  fail "active transfer intent unexpectedly passed preflight"
fi
grep -q $'transfer.intent\tPRECONDITION' "$intent/out"
! grep -q '^darkmesh-transfer ' "$intent/state/calls"

echo "5. captive field profile stops for sign-in and resumes exact state"
captive="$(new_fixture captive)"
if run_experiment "$captive" env TEST_CAPTIVE_PORTAL=yes \
  "$ROOT/scripts/darkmesh-experiment" run --profile captive >"$captive/first.out" 2>&1; then
  fail "captive field stage unexpectedly completed without owner sign-in"
else
  [[ "$?" -eq 3 ]] || fail "captive field stage did not return the owner-input status"
fi
captive_run="$(ls -1d "$captive/runs"/*)"
grep -q 'Captive standdown is active' "$captive/first.out"
run_experiment "$captive" env "$ROOT/scripts/darkmesh-experiment" run \
  --profile captive --resume "$captive_run" >"$captive/resume.out"
grep -q '"restoration_verified": true' "$captive_run/summary.json"
test -f "$captive_run/cases/captive-resume.json"

echo "6. full adaptive campaign records all dimensions and exact restoration"
full="$(new_fixture full)"
run_experiment "$full" env TEST_UNSUPPORTED_PROTOCOLS=lightwaytcp,lightwayudp \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$full/out"
run_dir="$(ls -1d "$full/runs"/*)"
test -f "$run_dir/cases/screen-wireguard-3.json"
test -f "$run_dir/cases/screen-lightwaytcp-1.json"
test -f "$run_dir/cases/screen-lightwayudp-1.json"
test -f "$run_dir/cases/split-wireguard-extension-only.json"
test -f "$run_dir/cases/split-wireguard-app-only.json"
test -f "$run_dir/cases/split-wireguard-neither.json"
test -f "$run_dir/cases/split-wireguard-disabled.json"
test -f "$run_dir/cases/startup-wireguard-vpn-first.json"
test -f "$run_dir/cases/startup-wireguard-restart.json"
test -f "$run_dir/cases/repeat-wireguard.json"
test -f "$run_dir/cases/production-wireguard-reconnect.json"
test -f "$run_dir/cases/production-wireguard-disconnect.json"
/usr/bin/python3 - "$run_dir/summary.json" "$run_dir/initial-state.json" "$run_dir/final-restoration.json" <<'PY'
import json,sys
s,i,f=map(lambda p:json.load(open(p)),sys.argv[1:])
assert s["restoration_verified"] is True
for key in ("state_protocol","state_region","state_split","state_rules","state_lock",
            "state_autoconnect","state_ts_id","state_ts_prefs","state_extensions",
            "state_vpn_intent","state_transfer_intent"):
    assert i[key] == f[key], key
assert f["state_vpn"] == "Disconnected"
PY
[[ "$(cat "$full/state/vpn-intent")" == off ]]
[[ "$(cat "$full/state/transfer-intent")" == paused ]]
! grep -q 'background' "$full/state/calls"
grep -q '^transfer-vpn-doctor --check$' "$full/state/calls"
[[ "$(stat -f %Lp "$run_dir")" == 700 ]]
[[ "$(stat -f %Lp "$run_dir/initial-state.json")" == 400 ]]
DARKMESH_EXPERIMENT_CONFIG="$full/missing-config" \
  "$ROOT/scripts/darkmesh-experiment" report "$run_dir" >"$full/report.out"
grep -q 'restoration verified: true' "$full/report.out"

echo "7. a connection timeout gets one recovered retry before elimination"
timeout="$(new_fixture timeout)"
if run_experiment "$timeout" env TEST_TIMEOUT_PROTOCOL=wireguard \
  TEST_UNSUPPORTED_PROTOCOLS=lightwaytcp,lightwayudp \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$timeout/out"; then
  fail "campaign with no surviving protocols unexpectedly passed"
fi
timeout_run="$(ls -1d "$timeout/runs"/*)"
test -f "$timeout_run/cases/screen-wireguard-timeout-retry.json"
/usr/bin/python3 - "$timeout_run/cases/screen-wireguard-1.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["outcome"]=="FAIL" and d["classification"]=="connection"
PY

echo "8. convergence fingerprint changes reset stability"
flap="$(new_fixture flap)"
if run_experiment "$flap" env TEST_FINGERPRINT_FLAP=yes \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$flap/out" 2>&1; then
  fail "permanent fingerprint flap unexpectedly converged"
fi
flap_run="$(ls -1d "$flap/runs"/*)"
grep -q '"event":"convergence-reset"' "$flap_run/observations.jsonl"

echo "9. signal interruption runs exact restoration"
signal="$(new_fixture signal)"
if run_experiment "$signal" env DARKMESH_EXPERIMENT_TEST_SIGNAL_AFTER_SNAPSHOT=yes \
  TEST_DELAYED_SPLIT_READ=yes TEST_RESTORE_COMMAND_WARNING=yes \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$signal/out" 2>&1; then
  fail "signal fixture unexpectedly passed"
fi
signal_run="$(ls -1d "$signal/runs"/*)"
grep -q '"event":"signal"' "$signal_run/observations.jsonl"
grep -q '"event":"restoration-command".*restore protocol returned nonzero' "$signal_run/observations.jsonl"
grep -q '"restoration_verified": true' "$signal_run/summary.json"
[[ ! -f "$signal/state/split-read-pending" ]]

echo "10. campaign deadman uses the same verified recovery path"
deadman="$(new_fixture deadman)"
if run_experiment "$deadman" env DARKMESH_EXPERIMENT_TEST_DEADMAN_AFTER_SNAPSHOT=yes \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$deadman/out" 2>&1; then
  fail "deadman fixture unexpectedly passed"
fi
deadman_run="$(ls -1d "$deadman/runs"/*)"
grep -q 'campaign deadman expired' "$deadman_run/deadman.log"
grep -q '"restoration_verified": true' "$deadman_run/summary.json"

echo "11. identity replacement is rejected and cannot be reported restored"
identity="$(new_fixture identity)"
if run_experiment "$identity" env TEST_IDENTITY_CHANGE=yes \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$identity/out" 2>&1; then
  fail "identity replacement unexpectedly passed"
fi
identity_run="$(ls -1d "$identity/runs"/*)"
grep -q '"restoration_verified": false' "$identity_run/summary.json"

echo "12. an exact-state restore failure is campaign-fatal"
restore="$(new_fixture restore)"
if run_experiment "$restore" env TEST_RESTORE_FAILURE=yes \
  DARKMESH_EXPERIMENT_TEST_SIGNAL_AFTER_SNAPSHOT=yes \
  "$ROOT/scripts/darkmesh-experiment" run --profile staged >"$restore/out" 2>&1; then
  fail "restore failure unexpectedly passed"
fi
restore_run="$(ls -1d "$restore/runs"/*)"
grep -q '"restoration_verified": false' "$restore_run/summary.json"

echo "13. legacy entrypoints are safe wrappers"
if "$ROOT/scripts/darkmesh-protocol-trial" >"$TMP/protocol.out" 2>&1; then
  fail "retired protocol trial unexpectedly ran"
fi
grep -q 'is retired' "$TMP/protocol.out"
"$ROOT/scripts/darkmesh-coexistence-trial" --help >"$TMP/wrapper.out" 2>&1
grep -q 'darkmesh experiment preflight' "$TMP/wrapper.out"

echo "14. guided start configures, gates, runs, and reports in one command"
guided="$(new_fixture guided)"
printf '%s\n' \
  'peer-one.example' 'ssh-one' 'peer-two.example' 'ssh-two' \
  'RUN STAGED EXPERIMENT' |
  run_experiment "$guided" env TEST_UNSUPPORTED_PROTOCOLS=lightwaytcp,lightwayudp \
    "$ROOT/scripts/darkmesh-experiment" start --reconfigure >"$guided/out"
grep -q 'Saved private experiment config:' "$guided/out"
grep -q 'Starting staged campaign' "$guided/out"
grep -q 'Latest report:' "$guided/out"
grep -q 'restoration verified: true' "$guided/out"
grep -q '^PEER_A_ADDRESS=peer-one.example$' "$guided/config"
grep -q '^PEER_A_SSH=ssh-one$' "$guided/config"
grep -q '^PEER_B_ADDRESS=peer-two.example$' "$guided/config"
grep -q '^PEER_B_SSH=ssh-two$' "$guided/config"
[[ "$(stat -f %Lp "$guided/config")" == 600 ]]

echo "15. guided start refuses the live campaign without exact confirmation"
cancelled="$(new_fixture cancelled)"
if printf '%s\n' \
  'peer-one.example' 'ssh-one' 'peer-two.example' 'ssh-two' 'not approved' |
  run_experiment "$cancelled" env "$ROOT/scripts/darkmesh-experiment" start \
    >"$cancelled/out" 2>&1; then
  fail "guided start ran without exact confirmation"
fi
grep -q 'live campaign cancelled' "$cancelled/out"
! grep -q '^expressvpnctl --timeout 8 connect' "$cancelled/state/calls"

echo "16. guided start supports the default config path under nounset"
default_home="$TMP/default-home"
default_fixture="$(new_fixture default-config)"
mkdir -p "$default_home/.config/darkmesh"
cp "$guided/config" "$default_home/.config/darkmesh/experiment.conf"
chmod 600 "$default_home/.config/darkmesh/experiment.conf"
if printf '%s\n' 'not approved' |
  run_experiment "$default_fixture" env HOME="$default_home" \
    DARKMESH_EXPERIMENT_CONFIG="$default_home/.config/darkmesh/experiment.conf" \
    "$ROOT/scripts/darkmesh-experiment" start >"$default_fixture/default.out" 2>&1; then
  fail "default-config guided start ran without exact confirmation"
fi
grep -q 'live campaign cancelled' "$default_fixture/default.out"
! grep -q 'unbound variable' "$default_fixture/default.out"

echo "darkmesh experiment tests passed"

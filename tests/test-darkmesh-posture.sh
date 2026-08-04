#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-posture-tests)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; HOME_DIR="$TMP/home"; STATUS="$HOME_DIR/status.json"
mkdir -p "$BIN" "$HOME_DIR"
fail() { echo "FAIL: $*" >&2; exit 1; }
stub() { printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
write_status() {
  python3 - "$STATUS" "$1" "$2" <<'PY'
import datetime,json,sys
json.dump({"schema":4,"timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'),"max_age_seconds":60,"internet_ok":True,"vpn_state":sys.argv[2],"tailscale_ok":sys.argv[3]=='true',"pf":{"pf_anchor_evaluated":True}},open(sys.argv[1],'w'))
PY
}

stub healthcheck 'echo "{\"schema\":4,\"internet_ok\":true}"'
stub audit 'echo "{\"verdict\":\"GO\",\"checks\":[\"pf\"]}"'
stub doctor 'echo "binding-current"'
stub panic 'echo panic >> "$TEST_LOG"; python3 - "$DARKMESH_STATUS_FILE" <<"PY"
import datetime,json,sys
d=json.load(open(sys.argv[1])); d["vpn_state"]="Disconnected"; d["timestamp"]=datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"); json.dump(d,open(sys.argv[1],"w"))
PY'
stub up 'echo up >> "$TEST_LOG"; python3 - "$DARKMESH_STATUS_FILE" "${UP_MODE:-healthy}" <<"PY"
import datetime,json,sys
d=json.load(open(sys.argv[1])); d["vpn_state"]="Connected"; d["tailscale_ok"]=sys.argv[2] != "regress"; d["timestamp"]=datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"); json.dump(d,open(sys.argv[1],"w"))
PY'
stub repair 'echo repair >> "$TEST_LOG"; python3 - "$DARKMESH_STATUS_FILE" <<"PY"
import datetime,json,sys
d=json.load(open(sys.argv[1])); d["tailscale_ok"]=True; d["timestamp"]=datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"); json.dump(d,open(sys.argv[1],"w"))
PY'
stub Tailscale 'echo "$*" >> "$TEST_LOG"; if [[ "$1" == status ]]; then echo "{\"BackendState\":\"Running\",\"Health\":[],\"Self\":{\"Online\":true,\"TailscaleIPs\":[\"100.100.100.1\"]},\"Peer\":{\"opaque-key\":{\"HostName\":\"host-a\",\"DNSName\":\"host-a.example.\",\"Online\":true,\"Active\":true,\"Relay\":\"relay-a\",\"CurAddr\":\"192.0.2.4:41641\",\"TailscaleIPs\":[\"100.100.100.2\"],\"LastSeen\":\"2026-01-01T00:00:00Z\"}}}"; elif [[ "$1" == ping ]]; then echo "pong from host-a (100.100.100.2) via DERP(sea) in 64ms"; fi; if [[ "$1" == down ]]; then python3 - "$DARKMESH_STATUS_FILE" <<"PY"
import datetime,json,sys
d=json.load(open(sys.argv[1])); d["tailscale_ok"]=False; d["timestamp"]=datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"); json.dump(d,open(sys.argv[1],"w"))
PY
fi; exit 0'
stub route 'echo " interface: utun9"'
stub ifconfig 'printf "if0: flags=0\n\tinet 192.0.2.10\n\tstatus: active\n"'
stub nc 'exit 0'
stub ssh 'echo "ssh $*" >> "$TEST_LOG"; echo "{\"schema\":2,\"kind\":\"darkmesh-posture-report\",\"assessment\":{\"severity\":\"green\",\"state\":\"healthy\",\"reason\":\"ok\"}}"'
stub nice 'echo "nice $*" >> "$TEST_LOG"; shift 2; exec "$@"'

env_base=(HOME="$HOME_DIR" PATH="$BIN:/usr/bin:/bin" DARKMESH_POSTURE_FILE="$HOME_DIR/posture.json" DARKMESH_STATUS_FILE="$STATUS" DARKMESH_HEALTHCHECK="$BIN/healthcheck" DARKMESH_AUDIT="$BIN/audit" DARKMESH_TRANSFER_DOCTOR="$BIN/doctor" DARKMESH_UP="$BIN/up" DARKMESH_PANIC="$BIN/panic" DARKMESH_REPAIR_TAILSCALE="$BIN/repair" DARKMESH_TAILSCALE="$BIN/Tailscale" DARKMESH_ROUTE="$BIN/route" DARKMESH_IFCONFIG="$BIN/ifconfig" DARKMESH_NC="$BIN/nc" DARKMESH_SSH="$BIN/ssh" DARKMESH_NICE="$BIN/nice" DARKMESH_POSTURE_APPLY_DEADLINE=1 TEST_LOG="$TMP/actions.log")

echo '1. stable profiles expose transition semantics and strict capability gate'
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" profiles --json)"
python3 -c 'import json,sys; d=json.load(sys.stdin); p={x["id"]:x for x in d["profiles"]}; assert d["schema"]==2 and len(p)==8; assert p["internet-plain-transfer-contained"]["forbidden"]=={"vpn":True,"tailscale":True}; assert p["tailscale-required-vpn-optional"]["transition"]["attemptSecondary"] is False; assert p["tailscale-required-vpn-preferred"]["transition"]["attemptSecondary"] is True' <<<"$out" || fail "profiles"

echo '2. reports are mutation-free and preferred absence is yellow'
write_status Disconnected true
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" set tailscale-required-vpn-preferred >/dev/null
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" show)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["assessment"]["severity"]=="yellow" and d["assessment"]["state"]=="degraded"' <<<"$out" || fail "yellow preferred"
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" health --json >/dev/null
[[ ! -f "$TMP/actions.log" ]] || fail "health mutated network"

echo '3. forbidden presence is red'
write_status Connected true
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" set internet-plain-transfer-contained >/dev/null
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" show)"
python3 -c 'import json,sys; assert json.load(sys.stdin)["assessment"]["severity"]=="red"' <<<"$out" || fail "forbidden not red"

echo '3b. optional components are yellow but never automatically started'
write_status Disconnected true
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" set tailscale-required-vpn-optional >/dev/null
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" show)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["assessment"]["severity"]=="yellow" and d["profile"]["transition"]["attemptSecondary"] is False' <<<"$out" || fail "tailscale optional semantics"
write_status Connected false
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" set vpn-required-tailscale-optional >/dev/null
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" show)"
python3 -c 'import json,sys; assert json.load(sys.stdin)["assessment"]["severity"]=="yellow"' <<<"$out" || fail "vpn optional semantics"

echo '4. passive topology is non-mutating and active probe is explicit, bounded, and remotely niced'
printf 'host-a host-a host-a /opt/homebrew/bin/darkmesh\n' > "$HOME_DIR/peers.conf"
rm -f "$TMP/actions.log"
out="$(env "${env_base[@]}" DARKMESH_POSTURE_PEERS="$HOME_DIR/peers.conf" "$ROOT/scripts/darkmesh-posture" topology --json)"
python3 -c 'import json,sys; d=json.load(sys.stdin); p=d["peers"][0]; assert d["schema"]==2 and d["local"]["tailscale"]["selfOnline"] is True; assert p["online"] is True and p["addresses"]==["100.100.100.2"] and "tailscalePing" not in p' <<<"$out" || fail "passive topology"
[[ ! "$(cat "$TMP/actions.log" 2>/dev/null)" =~ ping ]] || fail "passive topology ran a Tailscale ping"
[[ ! "$(cat "$TMP/actions.log" 2>/dev/null)" =~ nice ]] || fail "passive topology ran SSH"
out="$(env "${env_base[@]}" DARKMESH_POSTURE_PEERS="$HOME_DIR/peers.conf" "$ROOT/scripts/darkmesh-posture" probe --json)"
python3 -c 'import json,sys; p=json.load(sys.stdin)["peers"][0]; assert p["tailscalePing"]["ok"] and p["tcp22"]["ok"] and p["ssh"]["available"]' <<<"$out" || fail "active probe"
grep -q '^ping --c 1 --until-direct=false --timeout 3s host-a$' "$TMP/actions.log" || fail "ping did not use supported bounded argv"
grep -q '^nice -n 19 ' "$TMP/actions.log" || fail "remote process not locally niced"
grep -q '/usr/bin/nice -n 19 /opt/homebrew/bin/darkmesh posture report --json' "$TMP/actions.log" || fail "remote command does not begin with nice"
python3 -c 'import json,sys; p=json.load(sys.stdin)["peers"][0]["tailscalePing"]; assert p["latencyMs"]==64 and p["path"]=="DERP(sea)"' <<<"$out" || fail "ping path metadata"

echo '4b. remote report carries audit and transfer doctor evidence'
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" report --json)"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["audit"]["ok"] and d["audit"]["result"]["verdict"]=="GO" and d["transferReadiness"]["stdout"]=="binding-current\n"' <<<"$out" || fail "remote report evidence"
[[ ! "$(cat "$TMP/actions.log")" =~ down ]] || fail "topology mutated Tailscale"

echo '5. plain profile panics then explicitly stops Tailscale and writes desired only on success'
write_status Connected true; rm -f "$TMP/actions.log" "$HOME_DIR/posture.json"
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply internet-plain-transfer-contained >/dev/null
grep -q '^panic$' "$TMP/actions.log" || fail "plain profile did not panic"
grep -q '^down$' "$TMP/actions.log" || fail "plain profile did not stop Tailscale"
grep -q 'internet-plain-transfer-contained' "$HOME_DIR/posture.json" || fail "successful apply not selected"

echo '6. required Tailscale invokes only guarded repair when absent'
write_status Disconnected false; rm -f "$TMP/actions.log"
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply tailscale-required-vpn-optional >/dev/null
grep -q '^repair$' "$TMP/actions.log" || fail "required Tailscale did not use guarded repair"
[[ ! "$(cat "$TMP/actions.log")" =~ ' up' ]] || fail "optional VPN was started"

echo '6a. already-satisfied optional posture preserves the working secondary path'
write_status Connected true; rm -f "$TMP/actions.log"
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply tailscale-required-vpn-optional >/dev/null
[[ ! -s "$TMP/actions.log" ]] || fail "satisfied optional posture bounced a working path"

echo '6b. Tailscale-first plans remove connected lower-priority VPN before repair'
write_status Connected false; rm -f "$TMP/actions.log"
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply tailscale-required-vpn-optional >/dev/null
order="$(cat "$TMP/actions.log")"; [[ "${order%%$'\n'*}" == "panic" && "$order" == *$'\nrepair'* ]] || fail "optional ordering"
write_status Connected false; rm -f "$TMP/actions.log"
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply tailscale-required-vpn-preferred >/dev/null
order="$(cat "$TMP/actions.log")"; [[ "${order%%$'\n'*}" == "panic" && "$order" == *$'\nrepair'* && "$order" == *$'\nup'* ]] || fail "preferred ordering"

echo '7. high secondary VPN regression rolls back and keeps desired unchanged'
write_status Disconnected true; env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" set tailscale-required-vpn-optional >/dev/null
rm -f "$TMP/actions.log"; set +e
env "${env_base[@]}" UP_MODE=regress "$ROOT/scripts/darkmesh-posture" apply tailscale-required-vpn-preferred > "$TMP/failure.json"
rc=$?; set -e
[[ "$rc" == 3 ]] || fail "regression exit=$rc"
grep -q '^up$' "$TMP/actions.log" && grep -q '^panic$' "$TMP/actions.log" || fail "primary regression was not rolled back"
grep -q 'tailscale-required-vpn-optional' "$HOME_DIR/posture.json" || fail "failed apply replaced desired profile"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["reason"]=="higher-priority-regression" and d["rollback"]["attempted"]' "$TMP/failure.json" || fail "rollback evidence"

echo '8. strict capability refusal performs no action and cannot claim applied'
rm -f "$TMP/actions.log"; set +e
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply dual-required-zero-general-egress-leak > "$TMP/strict.json"
rc=$?; set -e
[[ "$rc" == 4 ]] || fail "strict refusal exit=$rc"
[[ ! -f "$TMP/actions.log" ]] || fail "strict profile took action"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d["applied"] and d["reason"]=="capability-unavailable"' "$TMP/strict.json" || fail "strict refusal contract"

echo '9. apply requires fresh containment and respects an existing apply lock'
write_status Connected true; python3 - "$STATUS" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d["timestamp"]="2000-01-01T00:00:00Z"; json.dump(d,open(sys.argv[1],"w"))
PY
rm -f "$TMP/actions.log"; set +e
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply vpn-required-tailscale-optional > "$TMP/stale.json"
rc=$?; set -e
[[ "$rc" == 3 ]] || fail "stale preflight exit=$rc"
[[ ! -f "$TMP/actions.log" ]] || fail "stale preflight mutated"
write_status Connected true; mkdir -p "$HOME_DIR/.config/darkmesh"; touch "$HOME_DIR/.config/darkmesh/posture.apply.lock"; set +e
env "${env_base[@]}" "$ROOT/scripts/darkmesh-posture" apply vpn-required-tailscale-optional > "$TMP/locked.json"
rc=$?; set -e; rm -f "$HOME_DIR/.config/darkmesh/posture.apply.lock"
[[ "$rc" == 5 ]] || fail "apply lock exit=$rc"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["reason"]=="apply-in-progress"' "$TMP/locked.json" || fail "apply lock contract"

echo '10. dispatcher reaches posture commands without a network transition'
out="$(env "${env_base[@]}" "$ROOT/scripts/darkmesh" posture profiles --json)"
python3 -c 'import json,sys; assert json.load(sys.stdin)["schema"]==2' <<<"$out" || fail "dispatcher"
echo 'PASS: darkmesh posture deterministic tests'

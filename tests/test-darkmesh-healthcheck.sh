#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-tests)"
trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/bin"
mkdir -p "$STUBS" "$TMP/home"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "missing file $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected path $1"; }
assert_contains() { grep -q "$2" "$1" || fail "$1 does not contain $2"; }

write_stub() {
  local name="$1"
  shift
  {
    printf '#!/bin/bash\n'
    printf '%s\n' "$@"
  } > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

write_stub expressvpnctl '
if [[ "$*" == *"get connectionstate"* ]]; then printf "%s\n" "${TEST_VPN_STATE:-Disconnected}"; exit 0; fi
exit 0'

write_stub host '
last="${!#}"
if [[ "$*" == *"-t NS ."* && "${TEST_SYSTEM_DNS_OK:-0}" == 1 ]]; then echo ". name server a.root-servers.net."; exit 0; fi
if [[ "$#" -ge 4 && "$last" == "${TEST_DHCP_DNS:-8.8.8.8}" ]]; then echo "example.com has address 93.184.216.34"; exit 0; fi
if [[ "${TEST_SYSTEM_DNS_OK:-0}" == 1 ]]; then echo "example.com has address 93.184.216.34"; exit 0; fi
exit 1'

write_stub curl '
url="${!#}"
if [[ "$url" == *"captive.apple.com"* && "${TEST_APPLE_OK:-0}" == 1 ]]; then printf "Success"; exit 0; fi
if [[ "$url" == *"generate_204"* ]]; then
  [[ "$*" == *"%{http_code}"* ]] && printf "%s" "${TEST_GOOGLE_CODE:-000}"
  [[ "${TEST_GOOGLE_CODE:-000}" == 204 ]] && exit 0 || exit 28
fi
if [[ "$url" == *"remotedesktop-pa"* ]]; then printf "%s" "${TEST_CRD_CODE:-404}"; exit 0; fi
exit 1'

write_stub ping 'exit "${TEST_IP_RC:-0}"'
write_stub nc 'exit "${TEST_IP_RC:-0}"'
write_stub pgrep 'exit 0'
write_stub osascript 'printf "%s\n" "$*" >> "${TEST_NOTIFY_LOG:?}"; exit 0'
write_stub launchctl '
if [[ "$1" == print ]]; then exit 1; fi
exit 0'
write_stub scutil '
if [[ "$1" == --dns ]]; then
  [[ "${TEST_POISON_PRESENT:-1}" == 1 ]] && echo "  nameserver[0] : 100.64.0.53"
  echo "  nameserver[1] : ${TEST_DHCP_DNS:-8.8.8.8}"
fi
exit 0'
write_stub route '
echo "   gateway: ${TEST_GATEWAY:-192.168.1.1}"
echo " interface: ${TEST_INTERFACE:-en0}"
exit 0'
write_stub ipconfig '
echo "domain_name_server (ip_mult): {${TEST_DHCP_DNS:-8.8.8.8}}"
exit 0'
write_stub Tailscale '
if [[ "$1" == status ]]; then
  [[ "${TEST_TS_HANG:-0}" == 1 ]] && { kill -STOP $$; sleep 300; }
  echo "{\"BackendState\":\"Running\",\"Self\":{\"Online\":${TEST_TS_ONLINE:-true}}}"; exit 0
fi
printf "%s\n" "$*" >> "${TEST_TS_LOG:?}"
exit 0'
write_stub plain-restore 'printf "%s\n" restore >> "${TEST_PLAIN_LOG:?}"; exit 0'
write_stub root-helper '
verb="$1"; printf "%s\n" "$verb" >> "${TEST_ROOT_LOG:?}"
case "$verb" in
  dns-override)
    cat > "${DARKMESH_DNS_OVERRIDE_JOURNAL:?}" <<EOF
VERSION=1
INTERFACE=${TEST_INTERFACE:-en0}
SERVICE=Wi-Fi
GATEWAY=${TEST_GATEWAY:-192.168.1.1}
MODE=dhcp
VALUES=
OVERRIDE_DNS=${TEST_DHCP_DNS:-8.8.8.8}
CREATED_EPOCH=$(date +%s)
EOF
    ;;
  dns-restore)
    [[ "${TEST_RESTORE_FAIL:-0}" == 1 ]] && exit 1
    rm -f "${DARKMESH_DNS_OVERRIDE_JOURNAL:?}"
    ;;
esac
exit 0'

run_healthcheck() {
  local home="$1" ticks="$2" protect="${3:-yes}" args=(--watch --interval 0)
  [[ "$protect" == yes ]] && args+=(--protect-tailscale)
  mkdir -p "$home/.config/darkmesh" "$home/Library/Logs/darkmesh"
  printf 'on\n' > "$home/.config/darkmesh/vpn-desired"
  HOME="$home" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  EXPRESSVPN_CTL="$STUBS/expressvpnctl" TAILSCALE_CLI="$STUBS/Tailscale" \
  DARKMESH_ROOT_HELPER="$STUBS/root-helper" DARKMESH_NO_SUDO=1 \
  DARKMESH_PLAIN_RESTORE="$STUBS/plain-restore" \
  DARKMESH_BREAKER_LIB="$ROOT/scripts/darkmesh-breaker" \
  DARKMESH_BREAKER_FILE="$home/.config/darkmesh/breakers.json" \
  DARKMESH_STATUS_FILE="$home/status.json" \
  DARKMESH_RECONNECT_SIDECAR="$home/reconnect.json" \
  DARKMESH_PF_SIDECAR="$home/pf.json" \
  DARKMESH_RECONNECT_REQUEST="$home/.config/darkmesh/reconnect-request.json" \
  DARKMESH_DNS_OVERRIDE_JOURNAL="$home/dns-override.state" \
  DARKMESH_HEALTHCHECK_LOCK="$home/.config/darkmesh/healthcheck.lock" \
  DARKMESH_CRD_INSTALLED=no DARKMESH_INTERVAL=0 DARKMESH_MAX_TICKS="$ticks" \
  DARKMESH_BREAKER_COOLDOWN=0 \
  TEST_ROOT_LOG="$home/root.log" TEST_TS_LOG="$home/ts.log" TEST_NOTIFY_LOG="$home/notify.log" \
  TEST_PLAIN_LOG="$home/plain.log" \
  "$ROOT/scripts/darkmesh-healthcheck" "${args[@]}"
}

echo "1. one-shot is read-only and Apple body is honored"
ONE="$TMP/one"
mkdir -p "$ONE"
out="$(HOME="$ONE" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  EXPRESSVPN_CTL="$STUBS/expressvpnctl" TAILSCALE_CLI="$STUBS/Tailscale" \
  DARKMESH_CRD_INSTALLED=no DARKMESH_RECONNECT_SIDECAR="$ONE/reconnect.json" TEST_APPLE_OK=1 TEST_GOOGLE_CODE=500 \
  TEST_ROOT_LOG="$ONE/root.log" TEST_TS_LOG="$ONE/ts.log" TEST_NOTIFY_LOG="$ONE/notify.log" TEST_PLAIN_LOG="$ONE/plain.log" \
  "$ROOT/scripts/darkmesh-healthcheck")"
grep '"inet_e2e_ok": true' >/dev/null <<<"$out" || fail "Apple body probe did not pass"
assert_absent "$ONE/.config"
assert_absent "$ONE/Library"

echo "2. duplicate watch instance is refused"
LOCKHOME="$TMP/lock"
mkdir -p "$LOCKHOME/.config/darkmesh/healthcheck.lock"
printf '%s\n' "$$" > "$LOCKHOME/.config/darkmesh/healthcheck.lock/pid"
set +e
HOME="$LOCKHOME" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  EXPRESSVPN_CTL="$STUBS/expressvpnctl" TAILSCALE_CLI="$STUBS/Tailscale" \
  DARKMESH_HEALTHCHECK_LOCK="$LOCKHOME/.config/darkmesh/healthcheck.lock" \
  "$ROOT/scripts/darkmesh-healthcheck" --watch --interval 0 >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" == 75 ]] || fail "duplicate watcher exit=$rc, expected 75"

echo "2b. terminated watcher exits and removes its lock"
TERMINATE_HOME="$TMP/term"
mkdir -p "$TERMINATE_HOME/.config/darkmesh" "$TERMINATE_HOME/Library/Logs/darkmesh"
printf 'on\n' > "$TERMINATE_HOME/.config/darkmesh/vpn-desired"
HOME="$TERMINATE_HOME" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
  EXPRESSVPN_CTL="$STUBS/expressvpnctl" TAILSCALE_CLI="$STUBS/Tailscale" \
  DARKMESH_ROOT_HELPER="$STUBS/root-helper" DARKMESH_NO_SUDO=1 \
  DARKMESH_PLAIN_RESTORE="$STUBS/plain-restore" DARKMESH_BREAKER_LIB="$ROOT/scripts/darkmesh-breaker" \
  DARKMESH_BREAKER_FILE="$TERMINATE_HOME/.config/darkmesh/breakers.json" DARKMESH_STATUS_FILE="$TERMINATE_HOME/status.json" \
  DARKMESH_RECONNECT_SIDECAR="$TERMINATE_HOME/reconnect.json" DARKMESH_PF_SIDECAR="$TERMINATE_HOME/pf.json" \
  DARKMESH_RECONNECT_REQUEST="$TERMINATE_HOME/.config/darkmesh/reconnect-request.json" \
  DARKMESH_DNS_OVERRIDE_JOURNAL="$TERMINATE_HOME/dns-override.state" \
  DARKMESH_HEALTHCHECK_LOCK="$TERMINATE_HOME/.config/darkmesh/healthcheck.lock" DARKMESH_CRD_INSTALLED=no \
  TEST_ROOT_LOG="$TERMINATE_HOME/root.log" TEST_TS_LOG="$TERMINATE_HOME/ts.log" TEST_NOTIFY_LOG="$TERMINATE_HOME/notify.log" \
  TEST_PLAIN_LOG="$TERMINATE_HOME/plain.log" \
  "$ROOT/scripts/darkmesh-healthcheck" --watch --interval 30 >/dev/null 2>&1 &
term_pid=$!
for _ in {1..50}; do [[ -f "$TERMINATE_HOME/.config/darkmesh/healthcheck.lock/pid" ]] && break; sleep 0.02; done
kill -TERM "$term_pid"
for _ in {1..50}; do kill -0 "$term_pid" 2>/dev/null || break; sleep 0.02; done
kill -0 "$term_pid" 2>/dev/null && fail "watcher ignored TERM"
wait "$term_pid"
assert_absent "$TERMINATE_HOME/.config/darkmesh/healthcheck.lock"

echo "3. foreign resolver poison reaches DHCP override"
DNSHOME="$TMP/dns"
TEST_VPN_STATE=Disconnected TEST_SYSTEM_DNS_OK=0 TEST_APPLE_OK=0 TEST_GOOGLE_CODE=000 \
  TEST_POISON_PRESENT=1 TEST_DHCP_DNS=8.8.8.8 run_healthcheck "$DNSHOME" 3
assert_contains "$DNSHOME/root.log" dns-flush
assert_contains "$DNSHOME/root.log" dns-override
assert_file "$DNSHOME/dns-override.state"
assert_contains "$DNSHOME/status.json" '"dns_override_active": true'

echo "4. network change restores the temporary override"
RESTOREHOME="$TMP/restore"
mkdir -p "$RESTOREHOME"
cat > "$RESTOREHOME/dns-override.state" <<EOF
VERSION=1
INTERFACE=en0
SERVICE=Wi-Fi
GATEWAY=192.168.1.1
MODE=dhcp
VALUES=
OVERRIDE_DNS=8.8.8.8
CREATED_EPOCH=$(date +%s)
EOF
TEST_GATEWAY=192.168.2.1 TEST_VPN_STATE=Disconnected TEST_SYSTEM_DNS_OK=1 TEST_APPLE_OK=1 \
  TEST_GOOGLE_CODE=204 TEST_POISON_PRESENT=0 run_healthcheck "$RESTOREHOME" 1
assert_contains "$RESTOREHOME/root.log" dns-restore
assert_absent "$RESTOREHOME/dns-override.state"

echo "4b. failed restore is attempted once, not looped"
RESTOREFAIL="$TMP/restore-fail"
mkdir -p "$RESTOREFAIL"
cat > "$RESTOREFAIL/dns-override.state" <<EOF
VERSION=1
INTERFACE=en0
SERVICE=Wi-Fi
GATEWAY=192.168.1.1
MODE=dhcp
VALUES=
OVERRIDE_DNS=8.8.8.8
CREATED_EPOCH=$(date +%s)
EOF
TEST_RESTORE_FAIL=1 TEST_GATEWAY=192.168.2.1 TEST_VPN_STATE=Disconnected TEST_SYSTEM_DNS_OK=1 \
  TEST_APPLE_OK=1 TEST_GOOGLE_CODE=204 TEST_POISON_PRESENT=0 run_healthcheck "$RESTOREFAIL" 2
[[ "$(grep -c '^dns-restore$' "$RESTOREFAIL/root.log")" == 1 ]] || fail "failed restore repeated"
assert_file "$RESTOREFAIL/.config/darkmesh/dns-restore-failed"

echo "5. persistent breaker traverses two full cycles then opens once"
BREAKHOME="$TMP/break"
TEST_VPN_STATE=unknown TEST_SYSTEM_DNS_OK=0 TEST_APPLE_OK=0 TEST_GOOGLE_CODE=000 \
  TEST_POISON_PRESENT=1 TEST_DHCP_DNS=8.8.8.8 run_healthcheck "$BREAKHOME" 7
state="$(/usr/bin/plutil -extract breakers.dns_dead.state raw -o - "$BREAKHOME/.config/darkmesh/breakers.json")"
[[ "$state" == open ]] || fail "breaker state=$state"
[[ "$(wc -l < "$BREAKHOME/notify.log" | tr -d ' ')" == 1 ]] || fail "breaker alert was not coalesced"
assert_absent "$BREAKHOME/.config/darkmesh/reconnect-request.json"

echo "6. sustained VPN-path failure restores plain network once"
VPNFAIL="$TMP/vpnfail"
TEST_VPN_STATE=Connected TEST_SYSTEM_DNS_OK=0 TEST_APPLE_OK=0 TEST_GOOGLE_CODE=000 \
  TEST_IP_RC=0 TEST_TS_ONLINE=true DARKMESH_GRACE=0 DARKMESH_VPN_FAIL_TICKS_REQUIRED=2 \
  run_healthcheck "$VPNFAIL" 2 no
[[ "$(grep -c '^restore$' "$VPNFAIL/plain.log")" == 1 ]] || fail "plain restore was not called exactly once"
assert_contains "$VPNFAIL/status.json" '"auto_disconnected": true'

echo "7. Tailscale is status-only on a laptop"
TSHOME="$TMP/tailscale-optional"
TEST_VPN_STATE=Connected TEST_SYSTEM_DNS_OK=1 TEST_APPLE_OK=1 TEST_GOOGLE_CODE=204 \
  TEST_IP_RC=0 TEST_TS_ONLINE=false DARKMESH_GRACE=0 run_healthcheck "$TSHOME" 1 no
assert_contains "$TSHOME/status.json" '"verdict": "DEGRADED"'
assert_absent "$TSHOME/plain.log"

echo "8. a wedged Tailscale CLI cannot freeze the status writer"
HANGHOME="$TMP/tailscale-hang"
started="$(date +%s)"
TEST_VPN_STATE=Connected TEST_SYSTEM_DNS_OK=1 TEST_APPLE_OK=1 TEST_GOOGLE_CODE=204 \
  TEST_IP_RC=0 TEST_TS_HANG=1 DARKMESH_PROBE_DEADLINE=1 DARKMESH_GRACE=0 \
  run_healthcheck "$HANGHOME" 1 no >/dev/null
elapsed=$(( $(date +%s) - started ))
[[ "$elapsed" -le 4 ]] || fail "wedged Tailscale held tick for ${elapsed}s"
assert_contains "$HANGHOME/status.json" '"tailscale_ok": false'
assert_contains "$HANGHOME/status.json" '"schema": 4'
assert_contains "$HANGHOME/status.json" '"max_age_seconds": 60'

echo "PASS: darkmesh healthcheck deterministic tests"

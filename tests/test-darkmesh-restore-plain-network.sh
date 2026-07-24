#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-plain-test)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

stub() {
  local name="$1" body="$2"
  printf '#!/bin/bash\n%s\n' "$body" > "$BIN/$name"
  chmod +x "$BIN/$name"
}

stub expressvpnctl 'printf "%s\n" "$*" >> "${TEST_CTL_LOG:?}"; exit 0'
stub Tailscale 'printf "%s\n" "$*" >> "${TEST_TS_LOG:?}"; exit 0'
stub root-helper 'printf "%s\n" "$*" >> "${TEST_ROOT_LOG:?}"; exit 0'
stub vpn-guard.sh 'printf "%s\n" "$*" >> "${TEST_GUARD_LOG:?}"; exit 0'
stub host 'exit "${TEST_DNS_RC:-1}"'

run_restore() {
  PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" EXPRESSVPN_CTL="$BIN/expressvpnctl" \
    TAILSCALE_CLI="$BIN/Tailscale" DARKMESH_ROOT_HELPER="$BIN/root-helper" \
    DARKMESH_VPN_GUARD="$BIN/vpn-guard.sh" DARKMESH_NO_SUDO=1 \
    TEST_CTL_LOG="$TMP/ctl.log" TEST_TS_LOG="$TMP/ts.log" TEST_ROOT_LOG="$TMP/root.log" \
    TEST_GUARD_LOG="$TMP/guard.log" TEST_DNS_RC=1 \
    "$ROOT/scripts/darkmesh-restore-plain-network" --quiet
}

run_restore
run_restore

[[ "$(grep -c '^--force-unsafe$' "$TMP/guard.log")" == 2 ]] || { echo "transfer guard was not forced unsafe" >&2; exit 1; }
[[ "$(grep -c '^set autoconnect false$' "$TMP/ctl.log")" == 2 ]] || { echo "autoconnect was not disabled" >&2; exit 1; }
[[ "$(grep -c '^set networklock false$' "$TMP/ctl.log")" == 2 ]] || { echo "Network Lock was not disabled" >&2; exit 1; }
[[ "$(grep -c 'disconnect' "$TMP/ctl.log")" == 2 ]] || { echo "VPN was not disconnected idempotently" >&2; exit 1; }
[[ "$(grep -c '^set --accept-dns=false$' "$TMP/ts.log")" == 2 ]] || { echo "Tailscale DNS acceptance was not disabled" >&2; exit 1; }
! grep -qE '(^| )down($| )' "$TMP/ts.log" || { echo "Tailscale was turned off" >&2; exit 1; }
[[ "$(grep -c '^dns-restore$' "$TMP/root.log")" == 2 ]] || { echo "DNS journal was not restored" >&2; exit 1; }
[[ "$(grep -c '^dns-flush$' "$TMP/root.log")" == 2 ]] || { echo "DNS was not flushed" >&2; exit 1; }
[[ "$(grep -c '^dns-override$' "$TMP/root.log")" == 2 ]] || { echo "DHCP fallback was not evaluated" >&2; exit 1; }

echo "PASS: plain-network restore is idempotent and leaves Tailscale optional"

rm -f "$TMP/ctl.log"
stub failing-guard 'exit 1'
if PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" EXPRESSVPN_CTL="$BIN/expressvpnctl" \
    TAILSCALE_CLI="$BIN/Tailscale" DARKMESH_ROOT_HELPER="$BIN/root-helper" \
    DARKMESH_VPN_GUARD="$BIN/failing-guard" DARKMESH_NO_SUDO=1 \
    TEST_CTL_LOG="$TMP/ctl.log" TEST_TS_LOG="$TMP/ts.log" TEST_ROOT_LOG="$TMP/root.log" \
    TEST_GUARD_LOG="$TMP/guard.log" TEST_DNS_RC=1 \
    "$ROOT/scripts/darkmesh-restore-plain-network" --quiet; then
  echo "restore proceeded without confirmed transfer containment" >&2
  exit 1
fi
[[ ! -e "$TMP/ctl.log" ]] || { echo "VPN changed after containment failure" >&2; exit 1; }

echo "PASS: containment failure prevents the plain-network transition"

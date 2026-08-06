#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t vpn-guard-tests)"
HOME="$TMP/home"
mkdir -p "$HOME/.config/vpn-guard"

# Sourcing exposes the detection functions without executing enforcement.
# Replace the live probes with deterministic fixtures after loading the file.
source "$ROOT/vpn-guard/vpn-guard.sh"
trap 'rm -f "$COOKIE_JAR"; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_hotspot() { is_hotspot || fail "$1 was not classified as a hotspot"; }
assert_not_hotspot() { ! is_hotspot || fail "$1 was classified as a hotspot"; }

TEST_IP="192.168.1.20"
TEST_MAC="02:11:22:33:44:55"
TEST_SSID=""
HOTSPOT_PATTERNS_FILE="$HOME/.config/vpn-guard/hotspot-ssids.txt"
TRUSTED_GATEWAY_MACS_FILE="$HOME/.config/vpn-guard/trusted-gateway-macs.txt"

log() { :; }
active_wifi_iface() { printf 'en0'; }
default_route_iface() { printf 'en0'; }
default_gateway() { printf '192.168.1.1'; }
current_ssid() {
  [[ -n "${TEST_SSID:-}" ]] || return 1
  printf '%s' "$TEST_SSID"
}
ipconfig() {
  [[ "$1" == "getifaddr" ]] && printf '%s\n' "$TEST_IP"
}
arp() {
  printf '? (192.168.1.1) at %s on en0 ifscope [ethernet]\n' "$TEST_MAC"
}

echo "1. unknown locally-administered gateway remains fail-closed"
assert_hotspot "unknown gateway"

echo "2. exact trusted gateway suppresses only the ambiguous MAC signal"
cat > "$TRUSTED_GATEWAY_MACS_FILE" <<'EOF'
# Case and whitespace are ignored.
  02:11:22:33:44:55
EOF
assert_not_hotspot "trusted gateway"

echo "3. a known tether subnet overrides the trusted gateway"
TEST_IP="172.20.10.2"
assert_hotspot "known tether subnet"

echo "4. an explicit SSID match overrides the trusted gateway"
TEST_IP="192.168.1.20"
TEST_SSID="Travel Handset"
printf 'Handset\n' > "$HOTSPOT_PATTERNS_FILE"
assert_hotspot "explicit SSID"

echo "5. an ordinary burned-in gateway remains allowed"
TEST_SSID=""
TEST_MAC="00:11:22:33:44:55"
assert_not_hotspot "ordinary gateway"

echo "6. forced unsafe mode uses only transfer containment actions"
EVENTS="$TMP/events.log"
ensure_pf_enabled() { echo pf-enable >> "$EVENTS"; }
apply_pf_unsafe() { echo pf-unsafe >> "$EVENTS"; }
client_pause_all() { echo client-pause >> "$EVENTS"; }
incident_contain() { echo incident-contain >> "$EVENTS"; }
write_pf_sidecar() { echo "sidecar-$1" >> "$EVENTS"; }
is_vpn_connected() { fail "forced unsafe unexpectedly probed VPN"; }
is_hotspot() { fail "forced unsafe unexpectedly probed hotspot"; }
main --force-unsafe
[[ "$(tr '\n' ' ' < "$EVENTS")" == "pf-enable pf-unsafe incident-contain sidecar-true " ]] \
  || fail "forced unsafe action sequence was incorrect"

echo "7. a manual pause is honored and unchanged ticks are quiet"
: > "$EVENTS"
mkdir -p "$HOME/.config/darkmesh"
printf 'paused\n' > "$HOME/.config/darkmesh/transfer-desired"
GUARD_STATE_FILE="$HOME/.config/darkmesh/vpn-guard-state"
TRANSFER_DESIRED_FILE="$HOME/.config/darkmesh/transfer-desired"
REASSERT_SECONDS=600
is_vpn_connected() { return 0; }
is_hotspot() { return 1; }
apply_pf_safe() { echo pf-safe >> "$EVENTS"; }
client_pause_all() { echo client-pause >> "$EVENTS"; }
incident_pending() { return 1; }
write_pf_sidecar() { echo "sidecar-$1" >> "$EVENTS"; }
main
main
[[ "$(tr '\n' ' ' < "$EVENTS")" == "pf-safe client-pause sidecar-false sidecar-false " ]] \
  || fail "guard repeated unchanged enforcement or ignored manual pause"
grep -q '^transfer=paused$' "$GUARD_STATE_FILE" || fail "paused guard state was not persisted"

echo "8. PF status probing does not leak enable references under pipefail"
: > "$EVENTS"
sudo() {
  shift 2
  if [[ "$*" == "-s info" ]]; then
    printf 'Status: Enabled\n'
    for _ in {1..200}; do printf 'counter data that must be drained\n'; done
    return 0
  fi
  [[ "$*" != "-E" ]] || echo pf-enable >> "$EVENTS"
}
ensure_pf_enabled() {
  pf_enabled_now && return 0
  run_pf_quiet -E
}
pf_enabled_now || fail "enabled PF was misclassified under pipefail"
ensure_pf_enabled
[[ ! -s "$EVENTS" ]] || fail "enabled PF acquired another enable reference"

echo "9. incident recovery verifies, flushes, re-verifies, and targets the journal owner"
: > "$EVENTS"
printf 'active\n' > "$TRANSFER_DESIRED_FILE"
cat > "$GUARD_STATE_FILE" <<EOF
mode=unsafe
transfer=paused
last_action_at=$(date +%s)
EOF
incident_pending() { return 0; }
incident_ready() { echo incident-ready >> "$EVENTS"; }
incident_recover() { echo incident-recover >> "$EVENTS"; }
client_thaw_for_recovery() { echo client-thaw >> "$EVENTS"; }
ensure_pf_enabled() { echo pf-enable >> "$EVENTS"; }
apply_pf_unsafe() { echo pf-unsafe >> "$EVENTS"; }
apply_pf_safe() { echo pf-safe >> "$EVENTS"; }
write_pf_sidecar() { echo "sidecar-$1" >> "$EVENTS"; }
main
[[ "$(tr '\n' ' ' < "$EVENTS")" == "pf-enable pf-unsafe client-thaw incident-ready pf-safe incident-recover sidecar-false " ]] \
  || fail "incident recovery ordering was incorrect"

echo "10. failed post-flush recovery immediately re-arms containment"
: > "$EVENTS"
cat > "$GUARD_STATE_FILE" <<EOF
mode=unsafe
transfer=paused
last_action_at=$(date +%s)
EOF
incident_recover() { echo incident-recover-failed >> "$EVENTS"; return 1; }
ensure_pf_enabled() { echo pf-enable >> "$EVENTS"; }
apply_pf_unsafe() { echo pf-unsafe >> "$EVENTS"; }
main
[[ "$(tr '\n' ' ' < "$EVENTS")" == "pf-enable pf-unsafe client-thaw incident-ready pf-safe incident-recover-failed pf-enable pf-unsafe sidecar-true " ]] \
  || fail "failed recovery did not restore PF containment"
grep -q '^mode=unsafe$' "$GUARD_STATE_FILE" || fail "failed recovery persisted a false safe state"

echo "11. forced unsafe reports PF enforcement failure to plain-network recovery"
: > "$EVENTS"
ensure_pf_enabled() { echo pf-enable-failed >> "$EVENTS"; return 1; }
incident_contain() { echo incident-contain >> "$EVENTS"; }
if main --force-unsafe >/dev/null 2>&1; then fail "forced unsafe hid PF enforcement failure"; fi
[[ "$(tr '\n' ' ' < "$EVENTS")" == "pf-enable-failed incident-contain sidecar-true " ]] \
  || fail "forced unsafe failure path did not retain app containment evidence"

echo "PASS: vpn-guard hotspot tests"

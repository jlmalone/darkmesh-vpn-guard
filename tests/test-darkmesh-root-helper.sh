#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-root-helper-runtime-test)"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
STATE="$TMP/state"
LOG="$TMP/root-helper.log"
CALLS="$TMP/networksetup.calls"
HELPER="$TMP/darkmesh-root-helper"
mkdir -p "$BIN" "$STATE"

sed \
  -e 's|^PATH=/usr/bin:/bin:/usr/sbin:/sbin$|PATH="${TEST_BIN:?}:/usr/bin:/bin:/usr/sbin:/sbin"|' \
  -e 's|^STATE_DIR=/Library/darkmesh/state$|STATE_DIR="${TEST_STATE_DIR:?}"|' \
  -e 's|^CONFIG_DIR=/Library/darkmesh/config$|CONFIG_DIR="${TEST_CONFIG_DIR:?}"|' \
  -e 's|^LOG=/var/log/darkmesh-root-helper.log$|LOG="${TEST_LOG:?}"|' \
  -e 's|^\[\[ "$(id -u)" -eq 0 \]\].*$|: # root check bypassed only in generated test copy|' \
  -e 's|^install -d -o root -g wheel -m 0755 "$STATE_DIR" "$CONFIG_DIR"$|mkdir -p "$STATE_DIR" "$CONFIG_DIR"|' \
  "$ROOT/scripts/darkmesh-root-helper" > "$HELPER"
chmod +x "$HELPER"

cat > "$BIN/networksetup" <<'EOF'
#!/bin/bash
case "$1" in
  -listnetworkserviceorder)
    printf '(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n'
    ;;
  -getdnsservers)
    printf '%s\n' "${TEST_CURRENT_DNS:?}"
    ;;
  -setdnsservers)
    printf '%s\n' "$*" >> "${TEST_CALLS:?}"
    ;;
esac
EOF

cat > "$BIN/route" <<'EOF'
#!/bin/bash
printf '   gateway: 192.168.1.1\n interface: en0\n'
EOF

cat > "$BIN/ipconfig" <<'EOF'
#!/bin/bash
printf 'domain_name_server (ip_mult): {8.8.8.8, 64.6.64.6}\n'
EOF

for command in dscacheutil killall chown; do
  printf '#!/bin/bash\nexit 0\n' > "$BIN/$command"
done
chmod +x "$BIN"/*

run_helper() {
  TEST_BIN="$BIN" TEST_STATE_DIR="$STATE" TEST_CONFIG_DIR="$TMP/config" \
    TEST_LOG="$LOG" TEST_CALLS="$CALLS" TEST_CURRENT_DNS="${TEST_CURRENT_DNS:?}" \
    "$HELPER" "$1"
}

echo "1. a CGNAT resolver is never journaled as durable static DNS"
TEST_CURRENT_DNS=100.64.0.53 run_helper dns-override
grep -q '^MODE=dhcp$' "$STATE/dns-override.state"
grep -q '^VALUES=$' "$STATE/dns-override.state"
grep -q '^-setdnsservers Wi-Fi 8.8.8.8 64.6.64.6$' "$CALLS"

echo "2. a legacy poisoned journal retires to DHCP"
cat > "$STATE/dns-override.state" <<'EOF'
VERSION=1
INTERFACE=en0
SERVICE=Wi-Fi
GATEWAY=192.168.1.1
MODE=static
VALUES=100.64.0.53
OVERRIDE_DNS=8.8.8.8 64.6.64.6
CREATED_EPOCH=1
EOF
: > "$CALLS"
TEST_CURRENT_DNS=8.8.8.8 run_helper dns-restore
grep -q '^-setdnsservers Wi-Fi Empty$' "$CALLS"
[[ ! -e "$STATE/dns-override.state" ]]
grep -q 'mode=dhcp-discarded-volatile' "$LOG"

echo "3. an ordinary static resolver remains restorable"
cat > "$STATE/dns-override.state" <<'EOF'
VERSION=1
INTERFACE=en0
SERVICE=Wi-Fi
GATEWAY=192.168.1.1
MODE=static
VALUES=1.1.1.1
OVERRIDE_DNS=8.8.8.8 64.6.64.6
CREATED_EPOCH=1
EOF
: > "$CALLS"
TEST_CURRENT_DNS=8.8.8.8 run_helper dns-restore
grep -q '^-setdnsservers Wi-Fi 1.1.1.1$' "$CALLS"
[[ ! -e "$STATE/dns-override.state" ]]

echo "PASS: root helper never restores volatile VPN or tailnet DNS"

#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/darkmesh-transfer-daemon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_executable() {
  chmod 0755 "$1"
}

cat > "$TMP/expressvpnctl" <<'EOF'
#!/bin/bash
printf 'Connected\n'
EOF
cat > "$TMP/netstat" <<'EOF'
#!/bin/bash
printf '0/1 10.0.0.1 UGSc utun7\n'
EOF
cat > "$TMP/ifconfig" <<'EOF'
#!/bin/bash
printf 'utun7: flags=8051\n\tinet 10.20.30.40 --> 10.20.30.40 netmask 0xffffffff\n'
EOF
cat > "$TMP/nice" <<'EOF'
#!/bin/bash
shift 2
exec "$@"
EOF
cat > "$TMP/transfer-daemon" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$DARKMESH_TEST_ARGS"
exit 0
EOF
make_executable "$TMP/expressvpnctl"
make_executable "$TMP/netstat"
make_executable "$TMP/ifconfig"
make_executable "$TMP/nice"
make_executable "$TMP/transfer-daemon"

args_file="$TMP/args"
EXPRESSVPN_CTL="$TMP/expressvpnctl" \
NETSTAT_BIN="$TMP/netstat" \
IFCONFIG_BIN="$TMP/ifconfig" \
NICE_BIN="$TMP/nice" \
TRANSFER_DAEMON_BIN="$TMP/transfer-daemon" \
TRANSFER_CONFIG_DIR="$TMP/config" \
TRANSFER_DOWNLOAD_DIR="$TMP/downloads" \
DARKMESH_TEST_ARGS="$args_file" \
"$SCRIPT"

grep -Fxq -- '--bind-address-ipv4' "$args_file"
grep -Fxq -- '10.20.30.40' "$args_file"
grep -Fxq -- '--bind-address-ipv6' "$args_file"
grep -Fxq -- '::1' "$args_file"
grep -Fxq -- '--no-dht' "$args_file"
grep -Fxq -- '--no-lpd' "$args_file"
grep -Fxq -- '--no-portmap' "$args_file"

cat > "$TMP/expressvpnctl" <<'EOF'
#!/bin/bash
printf 'Disconnected\n'
EOF
make_executable "$TMP/expressvpnctl"

set +e
EXPRESSVPN_CTL="$TMP/expressvpnctl" \
NETSTAT_BIN="$TMP/netstat" \
IFCONFIG_BIN="$TMP/ifconfig" \
NICE_BIN="$TMP/nice" \
TRANSFER_DAEMON_BIN="$TMP/transfer-daemon" \
TRANSFER_CONFIG_DIR="$TMP/config" \
TRANSFER_DOWNLOAD_DIR="$TMP/downloads" \
"$SCRIPT" >/dev/null 2>&1
rc=$?
set -e

[[ "$rc" -eq 75 ]]
echo "ok"

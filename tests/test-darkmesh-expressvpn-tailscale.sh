#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-express-test)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; PKG="$TMP/package"; mkdir -p "$BIN" "$PKG"
CTL="$BIN/expressvpnctl"; TS="$BIN/Tailscale"; EXT="$TMP/tailscale-extension"
touch "$TS" "$EXT"; chmod +x "$TS"
cp "$ROOT/scripts/darkmesh-expressvpn-tailscale" "$PKG/"

cat > "$CTL" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${TEST_CTL_LOG:?}"
if [[ "$*" == "get split-app" ]]; then
  printf 'bypass:%s\nbypass:%s\n' "${TEST_TS:?}" "${TEST_EXT:?}"
fi
exit 0
EOF
chmod +x "$CTL"

cat > "$BIN/find" <<'EOF'
#!/bin/bash
printf '%s\n' "${TEST_EXT:?}"
EOF
cat > "$BIN/systemextensionsctl" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$PKG/darkmesh-up" <<'EOF'
#!/bin/bash
echo up >> "${TEST_UP_LOG:?}"
EOF
chmod +x "$BIN/find" "$BIN/systemextensionsctl" "$PKG/darkmesh-up"

PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" EXPRESSVPN_CTL="$CTL" TAILSCALE_APP="$TS" \
  TEST_CTL_LOG="$TMP/ctl.log" TEST_UP_LOG="$TMP/up.log" \
  TEST_TS="$TS" TEST_EXT="$EXT" \
  "$PKG/darkmesh-expressvpn-tailscale" apply >/dev/null

grep -q '^set autoconnect false$' "$TMP/ctl.log" || { echo "apply did not disable autoconnect" >&2; exit 1; }
grep -q '^set networklock false$' "$TMP/ctl.log" || { echo "apply did not leave Network Lock off" >&2; exit 1; }
! grep -q '^connect$' "$TMP/ctl.log" || { echo "apply connected outside Darkmesh ordering" >&2; exit 1; }
grep -q '^up$' "$TMP/up.log" || { echo "apply did not resolve its installed sibling darkmesh-up" >&2; exit 1; }

echo "PASS: ExpressVPN apply leaves connection ordering to Darkmesh"

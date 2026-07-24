#!/bin/bash
# vpn-guard-install.sh - installs vpn-guard on macOS.
# Run once. Requires sudo. Re-running is safe.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(id -un)"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-vpn-guard-client}"
CLIENT_WEB_HOST="${CLIENT_WEB_HOST:-http://127.0.0.1:8080}"
CLIENT_WEB_USER="${CLIENT_WEB_USER:-admin}"

# --pf-only: install the PF kill-switch + script + sudoers WITHOUT the client
# Web-UI credential setup (for nodes where the client isn't running or the creds
# aren't handy). Pause/resume then uses the SIGSTOP fallback until creds are added.
PF_ONLY=0
for a in "$@"; do case "$a" in --pf-only) PF_ONLY=1 ;; esac; done

# Real transfer-client specifics (app / process / .ini section / API base) load
# from untracked local config; this public repo ships only neutral fallbacks.
CLIENT_CONF_FILE="${DARKMESH_CLIENT_CONF:-$HOME/.config/darkmesh/transfer-client.conf}"
[ -r "$CLIENT_CONF_FILE" ] && . "$CLIENT_CONF_FILE"

CLIENT_PROC="${CLIENT_PROC:-TransferClient}"
LEGACY_KEYCHAIN_SERVICE="${LEGACY_KEYCHAIN_SERVICE:-vpn-guard-legacy}"

echo "==> vpn-guard setup for user: $USER_NAME"

# 1) Verify ExpressVPN app.
if [[ ! -x /Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl ]]; then
  echo "ERROR: /Applications/ExpressVPN.app not found. Install ExpressVPN first." >&2
  exit 1
fi

# 2) Verify transfer client process.
if ! pgrep -x "$CLIENT_PROC" >/dev/null; then
  echo "WARN: transfer client is not currently running; setup can continue."
fi

verify_client_password() {
  local pw="$1" body http body_file cookie_file
  body_file="/tmp/.vpn-guard-setup-body"
  cookie_file="/tmp/.vpn-guard-setup-cookie"
  http="$(curl -sS --max-time 5 \
    -o "$body_file" \
    -w '%{http_code}' \
    -c "$cookie_file" \
    -H "Referer: $CLIENT_WEB_HOST" \
    --data-urlencode "username=$CLIENT_WEB_USER" \
    --data-urlencode "password=$pw" \
    "$CLIENT_WEB_HOST/api/v2/auth/login" 2>/dev/null)"
  body="$(cat "$body_file" 2>/dev/null)"
  rm -f "$cookie_file" "$body_file"
  case "$http:$body" in
    204:*)   return 0 ;;
    200:Ok.) return 0 ;;
    *)       return 1 ;;
  esac
}

store_pw_in_keychain() {
  security add-generic-password -a "$USER_NAME" -s "$KEYCHAIN_SERVICE" -w "$1" -U
}

if [[ "$PF_ONLY" == 1 ]]; then
  echo "==> --pf-only: skipping client Web-UI credential setup (pause/resume uses the SIGSTOP fallback until creds are added)."
else

if ! pgrep -x "$CLIENT_PROC" >/dev/null; then
  echo "ERROR: transfer client is not running. Start it before running setup so the" >&2
  echo "       Web UI password can be validated. (Or re-run with --pf-only to install" >&2
  echo "       just the PF kill-switch now and add client creds later.)" >&2
  exit 1
fi

if security find-generic-password -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1 || security find-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
  EXISTING_SERVICE="$KEYCHAIN_SERVICE"
  if ! security find-generic-password -s "$EXISTING_SERVICE" -w >/dev/null 2>&1; then
    EXISTING_SERVICE="$LEGACY_KEYCHAIN_SERVICE"
  fi
  EXISTING_PW="$(security find-generic-password -s "$EXISTING_SERVICE" -w 2>/dev/null)"
  if verify_client_password "$EXISTING_PW"; then
    echo "==> Transfer-client password already in Keychain and verified."
    if [[ "$EXISTING_SERVICE" != "$KEYCHAIN_SERVICE" ]]; then
      store_pw_in_keychain "$EXISTING_PW"
      echo "==> Migrated password to current Keychain service."
    fi
    echo "    To change it: security delete-generic-password -s $KEYCHAIN_SERVICE && ./vpn-guard-install.sh"
    echo "    Or in place:  security add-generic-password -a \"\$USER\" -s $KEYCHAIN_SERVICE -w NEWPASS -U"
  else
    echo "==> Keychain has a password but the client rejected it. Re-prompting."
    read -r -s -p "Transfer-client Web UI password (user=$CLIENT_WEB_USER, port=8080): " CLIENT_WEB_PW
    echo
    if ! verify_client_password "$CLIENT_WEB_PW"; then
      unset CLIENT_WEB_PW
      echo "ERROR: Password rejected by client at $CLIENT_WEB_HOST. Aborting." >&2
      exit 1
    fi
    store_pw_in_keychain "$CLIENT_WEB_PW"
    unset CLIENT_WEB_PW
    echo "==> Updated and verified."
  fi
  unset EXISTING_PW EXISTING_SERVICE
else
  echo "==> Storing transfer-client Web UI password in Keychain"
  read -r -s -p "Transfer-client Web UI password (user=$CLIENT_WEB_USER, port=8080): " CLIENT_WEB_PW
  echo
  if ! verify_client_password "$CLIENT_WEB_PW"; then
    unset CLIENT_WEB_PW
    echo "ERROR: Password rejected by client at $CLIENT_WEB_HOST. Did not store. Aborting." >&2
    exit 1
  fi
  store_pw_in_keychain "$CLIENT_WEB_PW"
  unset CLIENT_WEB_PW
  echo "==> Stored and verified."
fi

fi  # end PF_ONLY guard

# 3) Install script + PF rules.
sudo install -d -m 0755 /usr/local/etc/vpn-guard
sudo install -m 0755 "$REPO_DIR/vpn-guard.sh" /usr/local/bin/vpn-guard.sh
sudo install -m 0644 "$REPO_DIR/unsafe.pf.conf" /usr/local/etc/vpn-guard/unsafe.pf.conf
echo "==> Installed /usr/local/bin/vpn-guard.sh and /usr/local/etc/vpn-guard/unsafe.pf.conf"

# 4) Hotspot SSID list.
mkdir -p "$HOME/.config/vpn-guard"
if [[ ! -f "$HOME/.config/vpn-guard/hotspot-ssids.txt" ]]; then
  install -m 0644 "$REPO_DIR/hotspot-ssids.txt.example" "$HOME/.config/vpn-guard/hotspot-ssids.txt"
  echo "==> Wrote default hotspot list at ~/.config/vpn-guard/hotspot-ssids.txt"
fi

# 5) sudoers entry.
TMP_SUDO="$(mktemp)"
sed "s/^USERNAME /$USER_NAME /" "$REPO_DIR/sudoers.d-vpn-guard" > "$TMP_SUDO"
sudo visudo -cf "$TMP_SUDO" >/dev/null
sudo install -m 0440 -o root -g wheel "$TMP_SUDO" /etc/sudoers.d/vpn-guard
rm -f "$TMP_SUDO"
echo "==> Installed /etc/sudoers.d/vpn-guard (NOPASSWD pfctl for $USER_NAME)"

# 6) Initialize empty PF anchor so it exists for status checks.
sudo /sbin/pfctl -a com.apple/vpn-guard -F all 2>/dev/null || true

# 7) LaunchAgent.
LA_DIR="$HOME/Library/LaunchAgents"
LA_PATH="$LA_DIR/com.user.vpnguard.plist"
mkdir -p "$LA_DIR"
sed "s|__VPNGUARD_BIN__|/usr/local/bin/vpn-guard.sh|g" "$REPO_DIR/com.user.vpnguard.plist" > "$LA_PATH"
chmod 0644 "$LA_PATH"

launchctl bootout "gui/$(id -u)/com.user.vpnguard" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA_PATH"
launchctl enable "gui/$(id -u)/com.user.vpnguard"
echo "==> LaunchAgent installed and loaded"

# 8) Run once now.
/usr/local/bin/vpn-guard.sh && echo "==> First run ok"
echo
echo "Done. Logs:"
echo "  ~/Library/Logs/vpn-guard/vpn-guard.log"
echo "  /tmp/vpn-guard.std{out,err}.log"
echo
echo "Edit hotspot SSIDs:    ~/.config/vpn-guard/hotspot-ssids.txt"
echo "Force a re-check:      /usr/local/bin/vpn-guard.sh"
echo "Inspect PF anchor:     sudo pfctl -a com.apple/vpn-guard -s rules"
echo "Show stored password:  security find-generic-password -s $KEYCHAIN_SERVICE -w"
echo "Change password:       security delete-generic-password -s $KEYCHAIN_SERVICE && ./vpn-guard-install.sh"
echo "Update in place:       security add-generic-password -a \"\$USER\" -s $KEYCHAIN_SERVICE -w NEWPASS -U"
echo "Uninstall:             ./vpn-guard-uninstall.sh   (add --purge to also wipe Keychain + config)"

#!/bin/bash
# vpn-guard-uninstall.sh — remove vpn-guard cleanly.

set -uo pipefail

USER_NAME="$(id -un)"

launchctl bootout "gui/$(id -u)/com.user.vpnguard" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.user.vpnguard.plist"

sudo /sbin/pfctl -a com.apple/vpn-guard -F all 2>/dev/null || true
sudo /sbin/pfctl -a vpn-guard -F all 2>/dev/null || true  # legacy top-level anchor (pre-2026-06-16)
sudo rm -f /etc/sudoers.d/vpn-guard
sudo rm -f /usr/local/bin/vpn-guard.sh
sudo rm -rf /usr/local/etc/vpn-guard

# Keep keychain + user config; remove only if requested.
if [[ "${1:-}" == "--purge" ]]; then
  security delete-generic-password -s vpn-guard-client 2>/dev/null || true
  rm -rf "$HOME/.config/vpn-guard"
  rm -rf "$HOME/Library/Logs/vpn-guard"
  echo "==> Purged keychain entry and user config."
fi

echo "==> vpn-guard uninstalled."

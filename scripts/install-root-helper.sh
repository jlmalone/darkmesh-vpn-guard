#!/bin/bash
# One-time privileged install for the fixed darkmesh recovery helper.
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Run with sudo: sudo $0 [username]" >&2; exit 1; }

TARGET_USER="${1:-${SUDO_USER:-$(stat -f%Su /dev/console)}}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory | awk '{print $2}')"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC_DIR/.." && pwd)"
NEWSYSLOG_TEMPLATE=""
for candidate in "$ROOT/newsyslog/darkmesh.conf" "$SRC_DIR/newsyslog/darkmesh.conf"; do
  [[ -f "$candidate" ]] && { NEWSYSLOG_TEMPLATE="$candidate"; break; }
done
DST_DIR=/Library/darkmesh/bin
CONFIG_DIR=/Library/darkmesh/config
DST="$DST_DIR/darkmesh-root-helper"
SUDOERS=/etc/sudoers.d/darkmesh-root-helper
NEWSYSLOG=/etc/newsyslog.d/darkmesh.conf
CRD_TARGET_FILE="$CONFIG_DIR/crd-launchd-target"

[[ -f "$SRC_DIR/darkmesh-root-helper" ]] || { echo "ERROR: helper source missing" >&2; exit 1; }
[[ -n "$NEWSYSLOG_TEMPLATE" ]] || { echo "ERROR: newsyslog template missing" >&2; exit 1; }

install -d -o root -g wheel -m 0755 "$DST_DIR" "$CONFIG_DIR" /Library/darkmesh/state
install -o root -g wheel -m 0755 "$SRC_DIR/darkmesh-root-helper" "$DST"
touch /var/log/darkmesh-root-helper.log
chown root:wheel /var/log/darkmesh-root-helper.log
chmod 0640 /var/log/darkmesh-root-helper.log

crd_target=
for candidate in "system/org.chromium.chromoting" "gui/$TARGET_UID/org.chromium.chromoting"; do
  if launchctl print "$candidate" >/dev/null 2>&1; then crd_target="$candidate"; break; fi
done
if [[ -n "$crd_target" ]]; then
  printf '%s\n' "$crd_target" > "$CRD_TARGET_FILE"
  chown root:wheel "$CRD_TARGET_FILE"; chmod 0644 "$CRD_TARGET_FILE"
else
  rm -f "$CRD_TARGET_FILE"
fi

tmp="$(mktemp)"
{
  printf 'Cmnd_Alias DARKMESH_RECOVER = %s dns-flush, %s dns-override, %s dns-restore' "$DST" "$DST" "$DST"
  [[ -n "$crd_target" ]] && printf ', %s restart-crd' "$DST"
  printf '\n%s ALL=(root) NOPASSWD: DARKMESH_RECOVER\n' "$TARGET_USER"
} > "$tmp"
visudo -cf "$tmp" >/dev/null
install -o root -g wheel -m 0440 "$tmp" "$SUDOERS"
rm -f "$tmp"
visudo -cf "$SUDOERS" >/dev/null

tmp="$(mktemp)"
sed -e "s|__USER__|$TARGET_USER|g" \
    -e "s|__GROUP__|$TARGET_GROUP|g" \
    -e "s|__HOME__|$TARGET_HOME|g" \
    "$NEWSYSLOG_TEMPLATE" > "$tmp"
/usr/sbin/newsyslog -n -f "$tmp" >/dev/null
install -o root -g wheel -m 0644 "$tmp" "$NEWSYSLOG"
rm -f "$tmp"

# Remove the superseded broader/wrong-direction helper only after the new rule validates.
rm -f /etc/sudoers.d/darkmesh-dns-recover /Library/darkmesh/bin/darkmesh-dns-recover

echo "Installed $DST"
echo "Installed and validated $SUDOERS"
echo "Installed and validated $NEWSYSLOG"
if [[ -n "$crd_target" ]]; then
  echo "CRD restart target: $crd_target"
else
  echo "CRD restart unavailable: org.chromium.chromoting not loaded in system or user domain"
fi

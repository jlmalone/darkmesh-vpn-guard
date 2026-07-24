#!/bin/bash
# vpn-guard.sh - pause the transfer client and apply PF kill rules unless safe.
#
# Safe = ExpressVPN connected AND not on a personal-hotspot SSID.
# Otherwise: pause all client transfers via Web API and load a PF anchor that
# blocks the configured transfer ports. Run from a LaunchAgent on network change.

set -uo pipefail

EXPRESSVPN_CTL="${EXPRESSVPN_CTL:-/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl}"
CLIENT_WEB_HOST="${CLIENT_WEB_HOST:-http://127.0.0.1:8080}"
CLIENT_WEB_USER="${CLIENT_WEB_USER:-admin}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-vpn-guard-client}"
HOTSPOT_PATTERNS_FILE="${HOTSPOT_PATTERNS_FILE:-$HOME/.config/vpn-guard/hotspot-ssids.txt}"
TRUSTED_GATEWAY_MACS_FILE="${TRUSTED_GATEWAY_MACS_FILE:-$HOME/.config/vpn-guard/trusted-gateway-macs.txt}"
PF_RULES="${PF_RULES:-/usr/local/etc/vpn-guard/unsafe.pf.conf}"
# Nested under the com.apple/* wildcard that the macOS main ruleset always
# references, so the rules are actually EVALUATED. A top-level "vpn-guard" anchor
# loads fine but is never evaluated: stock /etc/pf.conf only references
# "com.apple/*" and ExpressVPN inserts "com.express.vpn/*" dynamically — neither
# hooks a top-level "vpn-guard". Verified 2026-06-16: a blocked port only drops
# traffic when the rules live here.
PF_ANCHOR="${PF_ANCHOR:-com.apple/vpn-guard}"
PF_SIDECAR="${PF_SIDECAR:-${DARKMESH_PF_SIDECAR:-/tmp/darkmesh-pf.json}}"
COOKIE_JAR="$(mktemp -t vpn-guard-client)"
LOG_DIR="$HOME/Library/Logs/vpn-guard"
LOG="$LOG_DIR/vpn-guard.log"

# Real transfer-client specifics (app / process / .ini section / API base) load
# from untracked local config; this public repo ships only neutral fallbacks.
CLIENT_CONF_FILE="${DARKMESH_CLIENT_CONF:-$HOME/.config/darkmesh/transfer-client.conf}"
[ -r "$CLIENT_CONF_FILE" ] && . "$CLIENT_CONF_FILE"

CLIENT_PROC="${CLIENT_PROC:-TransferClient}"
TRANSFER_ENDPOINT="${CLIENT_API_BASE:-transfers}"
LEGACY_KEYCHAIN_SERVICE="${LEGACY_KEYCHAIN_SERVICE:-vpn-guard-legacy}"

mkdir -p "$LOG_DIR"
trap 'rm -f "$COOKIE_JAR"' EXIT

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG" >&2; }

is_vpn_connected() {
  # Strict: requires the daemon to report active tunnel, not "app running but disconnected".
  # Live output (connected): first line is exactly "Connected to <region>".
  # Connecting or disconnected states are explicitly not considered safe.
  [[ -x "$EXPRESSVPN_CTL" ]] || { log "expressvpnctl missing at $EXPRESSVPN_CTL"; return 1; }
  local line
  line="$("$EXPRESSVPN_CTL" --timeout 3 status 2>/dev/null | head -n1)"
  [[ "$line" =~ ^Connected\ to\ [^[:space:]]+$ ]]
}

active_wifi_iface() {
  networksetup -listallhardwareports 2>/dev/null \
    | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}'
}

current_ssid() {
  local wifi
  wifi="$(active_wifi_iface || true)"
  [[ -z "$wifi" ]] && return 1
  local ssid
  # Legacy source; on modern macOS it reports "not associated" even while
  # connected, so the fallbacks below matter.
  ssid="$(networksetup -getairportnetwork "$wifi" 2>/dev/null \
    | sed -nE 's/^Current Wi-Fi Network: //p')"
  # wdutil reveals the SSID to root. No-op unless sudoers allows it
  # (add "NOPASSWD: /usr/bin/wdutil info" alongside the pfctl entry).
  [[ -n "$ssid" ]] || ssid="$(sudo -n /usr/bin/wdutil info 2>/dev/null \
    | sed -nE 's/^ *SSID *: *//p' | head -n1)"
  # Pre-Sequoia this works unredacted; newer macOS prints <redacted> without
  # Location Services, which a LaunchAgent shell never has.
  [[ -n "$ssid" ]] || ssid="$(ipconfig getsummary "$wifi" 2>/dev/null \
    | sed -nE 's/^ *SSID : (.*)$/\1/p' | head -n1)"
  [[ "$ssid" == "<redacted>" ]] && ssid=""
  [[ -n "$ssid" ]] || return 1
  printf '%s' "$ssid"
}

default_gateway() { route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'; }

default_route_iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'; }

# Second-least-significant bit of the first octet set = locally-administered
# (randomized) MAC. Phone hotspots randomize their AP MAC; home and office
# routers broadcast burned-in vendor MACs.
mac_is_locally_administered() {
  local o1="${1%%:*}"
  [[ "$o1" =~ ^[0-9a-fA-F]{1,2}$ ]] || return 1
  (( (16#$o1 & 2) != 0 ))
}

# A locally-administered gateway MAC is an intentionally conservative hotspot
# signal, but it is not unique to phones: mesh and privacy-oriented routers can
# use one too. Operators may exempt a known, stable gateway MAC without
# weakening the explicit SSID and tether-subnet checks above it.
gateway_mac_is_trusted() {
  local mac
  mac="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$mac" && -s "$TRUSTED_GATEWAY_MACS_FILE" ]] || return 1
  awk '
    {
      sub(/[[:space:]]*#.*/, "")
      gsub(/[[:space:]]/, "")
      if (length) print tolower($0)
    }
  ' "$TRUSTED_GATEWAY_MACS_FILE" | grep -qxF "$mac"
}

is_hotspot() {
  local ssid
  ssid="$(current_ssid 2>/dev/null || true)"
  if [[ -n "$ssid" ]]; then
    if [[ -s "$HOTSPOT_PATTERNS_FILE" ]]; then
      # Strip comments and blank lines; a blank grep pattern would match everything.
      grep -qiF -f <(grep -vE '^[[:space:]]*(#|$)' "$HOTSPOT_PATTERNS_FILE") <<<"$ssid" && return 0
    elif printf '%s' "$ssid" | grep -qiE 'iphone|android|hotspot|tether|personal|pixel|galaxy'; then
      return 0
    fi
  fi

  # SSID-free tether signatures. Modern macOS hides the SSID from scripts
  # (no Location Services), so a readable-SSID mismatch above must NOT be
  # treated as proof of safety. Apply only when traffic egresses over Wi-Fi.
  local wifi
  wifi="$(active_wifi_iface || true)"
  [[ -n "$wifi" && "$(default_route_iface)" == "$wifi" ]] || return 1

  # iPhone personal hotspots always assign 172.20.10.0/28.
  if ipconfig getifaddr "$wifi" 2>/dev/null | grep -q '^172\.20\.10\.'; then
    log "hotspot signal: iPhone tether subnet (172.20.10.x)"
    return 0
  fi

  # Classic AOSP tether subnet. Android 10 and earlier used this fixed range
  # with a burned-in AP MAC, so the randomized-MAC signal below misses them.
  if ipconfig getifaddr "$wifi" 2>/dev/null | grep -q '^192\.168\.43\.'; then
    log "hotspot signal: legacy Android tether subnet (192.168.43.x)"
    return 0
  fi

  # Randomized gateway MAC: phone hotspots use locally-administered AP MACs.
  local gw mac
  gw="$(default_gateway)" || return 1
  [[ -n "$gw" ]] || return 1
  mac="$(arp -n "$gw" 2>/dev/null | sed -nE 's/.* at ([0-9a-fA-F:]+) on .*/\1/p' | head -n1)"
  if [[ -n "$mac" ]] && mac_is_locally_administered "$mac"; then
    if gateway_mac_is_trusted "$mac"; then
      log "trusted gateway override: locally-administered MAC ($mac)"
      return 1
    fi
    log "hotspot signal: locally-administered gateway MAC ($mac)"
    return 0
  fi
  return 1
}

client_password() {
  security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null && return 0
  security find-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -w 2>/dev/null
}

client_login() {
  # Exit codes: 0 ok, 2 no keychain entry, 3 bad password, 4 unreachable/unexpected.
  local pw resp http body body_file
  body_file="/tmp/.vpn-guard-login-body.$$"
  pw="$(client_password)" || { log "ERROR: no client password in keychain (service=$KEYCHAIN_SERVICE) - re-run vpn-guard-install.sh"; return 2; }
  resp="$(curl -sS --max-time 5 \
    -o "$body_file" \
    -w '%{http_code}' \
    -c "$COOKIE_JAR" \
    -H "Referer: $CLIENT_WEB_HOST" \
    --data-urlencode "username=$CLIENT_WEB_USER" \
    --data-urlencode "password=$pw" \
    "$CLIENT_WEB_HOST/api/v2/auth/login" 2>>"$LOG")" || { log "ERROR: client Web UI unreachable at $CLIENT_WEB_HOST"; rm -f "$body_file"; return 4; }
  http="$resp"
  body="$(cat "$body_file" 2>/dev/null)"
  rm -f "$body_file"
  case "$http:$body" in
    204:*|200:Ok.)
      return 0 ;;
    200:Fails.|401:*)
      log "ERROR: client rejected credentials (user=$CLIENT_WEB_USER). Update keychain: security add-generic-password -a \$USER -s $KEYCHAIN_SERVICE -w NEWPASS -U"
      return 3 ;;
    403:*)
      log "ERROR: client returned 403 (IP banned for repeated failures? wait or restart the client)"
      return 3 ;;
    *)
      log "ERROR: client login unexpected response: HTTP $http body=[$body]"
      return 4 ;;
  esac
}

client_pause_all() {
  pgrep -x "$CLIENT_PROC" >/dev/null || { log "transfer client not running"; return 0; }
  client_login
  case $? in
    0) ;;
    2|3) log "WARN: client_login failed (auth/keychain); SIGSTOP fallback"; pkill -STOP -x "$CLIENT_PROC"; return 0 ;;
    *)   log "WARN: client_login failed (transport); SIGSTOP fallback"; pkill -STOP -x "$CLIENT_PROC"; return 0 ;;
  esac
  # Client API 2.11+ (app v5) renamed pause to stop; try new then legacy.
  local ep
  for ep in stop pause; do
    if curl -fsS --max-time 5 \
      -b "$COOKIE_JAR" \
      -H "Referer: $CLIENT_WEB_HOST" \
      --data "hashes=all" \
      "$CLIENT_WEB_HOST/api/v2/$TRANSFER_ENDPOINT/$ep" >>"$LOG" 2>&1; then
      log "client pause-all ok ($ep)"
      return 0
    fi
  done
  log "WARN: client pause-all failed; SIGSTOP fallback"
  pkill -STOP -x "$CLIENT_PROC"
}

client_resume_all() {
  pgrep -x "$CLIENT_PROC" >/dev/null || return 0
  pkill -CONT -x "$CLIENT_PROC" 2>/dev/null || true
  client_login || { log "WARN: client_login on resume failed (rc=$?)"; return 1; }
  # Client API 2.11+ (app v5) renamed resume to start; try new then legacy.
  local ep
  for ep in start resume; do
    if curl -fsS --max-time 5 \
      -b "$COOKIE_JAR" \
      -H "Referer: $CLIENT_WEB_HOST" \
      --data "hashes=all" \
      "$CLIENT_WEB_HOST/api/v2/$TRANSFER_ENDPOINT/$ep" >>"$LOG" 2>&1; then
      log "client resume-all ok ($ep)"
      return 0
    fi
  done
  log "WARN: client resume-all failed"
  return 1
}

# --- PF helpers --------------------------------------------------------------
# Kill rules live in the com.apple/vpn-guard anchor (see PF_ANCHOR). PF passes by
# default, so enabling it is safe for general connectivity — only our
# port-scoped rules ever block, and only while unsafe.

pf_enabled_now() {
  sudo -n /sbin/pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'
}

ensure_pf_enabled() {
  pf_enabled_now && return 0
  if sudo -n /sbin/pfctl -E >/dev/null 2>>"$LOG"; then
    log "pf enabled (was disabled)"
  else
    log "WARN: could not enable PF (need sudoers entry for 'pfctl -E'?)"
  fi
}

# Publish PF state for the healthcheck to merge into the status file (R2).
# pf_anchor_evaluated mirrors pf_enabled: the com.apple/* hook is structural, so
# the anchor evaluates whenever PF is on. kill_active = transfer ports blocked now.
write_pf_sidecar() {
  local kill_active="$1" enabled=false now tmp
  pf_enabled_now && enabled=true
  now="$(date -u +%FT%TZ)"
  tmp="$(mktemp -t darkmesh-pf)" || return 0
  cat > "$tmp" <<EOF
{
  "pf_enabled": $enabled,
  "pf_anchor": "$PF_ANCHOR",
  "pf_anchor_evaluated": $enabled,
  "pf_kill_active": $kill_active,
  "checked_at": "$now"
}
EOF
  mv -f "$tmp" "$PF_SIDECAR" 2>/dev/null || rm -f "$tmp"
}

apply_pf_unsafe() {
  [[ -r "$PF_RULES" ]] || { log "missing pf rules file: $PF_RULES"; return 1; }
  sudo -n /sbin/pfctl -a "$PF_ANCHOR" -f "$PF_RULES" 2>>"$LOG" \
    && log "pf anchor loaded (unsafe)" \
    || { log "pfctl load failed (need sudoers entry?)"; return 1; }
}

apply_pf_safe() {
  sudo -n /sbin/pfctl -a "$PF_ANCHOR" -F all 2>>"$LOG" \
    && log "pf anchor flushed (safe)" \
    || log "pfctl flush failed"
}

main() {
  if [[ "${1:-}" == --force-unsafe ]]; then
    log "forced unsafe: restoring transfer-client containment before network recovery"
    ensure_pf_enabled
    apply_pf_unsafe
    client_pause_all
    write_pf_sidecar true
    log "UNSAFE"
    return 0
  fi
  [[ $# -eq 0 ]] || { echo "Usage: vpn-guard.sh [--force-unsafe]" >&2; return 2; }

  local vpn=no hot=no
  is_vpn_connected && vpn=yes
  is_hotspot && hot=yes
  log "state: vpn=$vpn hotspot=$hot ssid=$(current_ssid 2>/dev/null || echo -)"

  if [[ "$vpn" == yes && "$hot" == no ]]; then
    apply_pf_safe
    client_resume_all
    write_pf_sidecar false
    log "SAFE"
  else
    ensure_pf_enabled
    apply_pf_unsafe
    client_pause_all
    write_pf_sidecar true
    log "UNSAFE"
  fi
}

# Run main only when executed directly; allows sourcing for tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

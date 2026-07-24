#!/bin/bash
# darkmesh.10s.sh — SwiftBar plugin showing darkmesh-vpn-guard protection state.
#
# Install:
#   1. brew install --cask swiftbar
#   2. mkdir -p "$HOME/Library/Application Support/SwiftBar/plugins"
#   3. defaults write com.ameba.SwiftBar PluginDirectory "$HOME/Library/Application Support/SwiftBar/plugins"
#   4. cp swiftbar/darkmesh.10s.sh "$HOME/Library/Application Support/SwiftBar/plugins/"
#   5. chmod +x "$HOME/Library/Application Support/SwiftBar/plugins/darkmesh.10s.sh"
#   6. open -a SwiftBar
#
# Source of truth: /tmp/darkmesh-status.json written by darkmesh-healthcheck.

# <swiftbar.title>darkmesh</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.author>darkmesh-vpn-guard</swiftbar.author>
# <swiftbar.desc>VPN+Tailscale+the transfer client protection status at a glance.</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

STATUS="${DARKMESH_STATUS_FILE:-/tmp/darkmesh-status.json}"
EXPRESSVPN=/Applications/ExpressVPN.app/Contents/MacOS/expressvpnctl
TAILSCALE=/Applications/Tailscale.app/Contents/MacOS/Tailscale
HEALTHCHECK="$HOME/.local/bin/darkmesh-healthcheck"

if [[ ! -r "$STATUS" ]]; then
  echo "⚠️ darkmesh"
  echo "---"
  echo "Healthcheck not running — status file missing"
  echo "Install: $HOME/IdeaProjects/darkmesh-vpn-guard/scripts/install-user-tools | bash=$HOME/IdeaProjects/darkmesh-vpn-guard/scripts/install-user-tools terminal=true refresh=true"
  exit 0
fi

IFS='|' read -r verdict state internet dns tailscale auto_disc auto_reason auto_at age < <(python3 - <<'PY' "$STATUS"
import datetime, json, os, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print('|'.join(('UNKNOWN','Unknown','false','false','false','false','','','unknown'))); sys.exit(0)
def b(x): return 'true' if x else 'false'
try:
    authored=datetime.datetime.fromisoformat(d['timestamp'].replace('Z','+00:00')).timestamp()
    age=max(0, time.time()-authored, time.time()-os.path.getmtime(sys.argv[1]))
except Exception:
    age=float('inf')
limit=d.get('max_age_seconds',60)
verdict='STALE' if age > limit else d.get('verdict','?')
def field(value): return str(value).replace('|','/').replace('\t',' ').replace('\n',' ')
print('|'.join((verdict,
      field(d.get('expressvpn_state','?')),
      b(d.get('internet_ok')),
      b(d.get('dns_ok')),
      b(d.get('tailscale_ok')),
      b(d.get('auto_disconnected')),
      field(d.get('auto_disconnect_reason','')),
      field(d.get('auto_disconnect_at','')),
      'unknown' if age == float('inf') else '%ds' % int(age))))
PY
)

case "$verdict" in
  GO)       emoji="🟢" ;;
  DEGRADED) emoji="🟡" ;;
  NO-GO)    emoji="🔴" ;;
  STALE)    emoji="❔" ;;
  IDLE)     emoji="⚪️" ;;
  *)        emoji="❔" ;;
esac

echo "$emoji $verdict"

echo "---"

echo "ExpressVPN: $state | font=Menlo size=11"
echo "Internet:   $([[ $internet == true ]]   && echo "✅ reachable" || echo "❌ unreachable") | font=Menlo size=11"
echo "DNS:        $([[ $dns == true ]]        && echo "✅ resolves"  || echo "❌ broken")     | font=Menlo size=11"
echo "Tailscale:  $([[ $tailscale == true ]]  && echo "✅ DERP ok"   || echo "❌ unreachable") | font=Menlo size=11"
[[ "$verdict" == STALE ]] && echo "Snapshot:    ❌ stale ($age old) | color=red font=Menlo size=11"

if [[ "$auto_disc" == "true" || -n "${auto_at//\"/}" ]]; then
  echo "---"
  echo "⚡️ Auto-disconnected at $auto_at | color=orange font=Menlo size=11"
  if [[ -n "${auto_reason//\"/}" ]]; then
    echo "   reason: $auto_reason | color=gray font=Menlo size=10"
  fi
fi

echo "---"

if [[ "$state" == "Connected" ]]; then
  echo "Disconnect VPN | bash=$EXPRESSVPN param1=disconnect terminal=false refresh=true"
else
  echo "Connect VPN | bash=$EXPRESSVPN param1=connect terminal=false refresh=true"
fi
echo "Run healthcheck now | bash=$HEALTHCHECK param1=--no-revert terminal=false refresh=true"
echo "Emergency restore internet | bash=$HOME/.local/bin/emergency-restore-internet terminal=true refresh=true"

echo "---"
echo "Open ExpressVPN | bash=/usr/bin/open param1=-a param2=ExpressVPN terminal=false"
echo "Open Tailscale  | bash=/usr/bin/open param1=-a param2=Tailscale terminal=false"
echo "Reveal status JSON in Finder | bash=/usr/bin/open param1=-R param2=$STATUS terminal=false"

#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-migrate-test)"
trap 'rm -rf "$TMP"' EXIT

if SERVER_MONITOR_APP="$TMP/missing" bash "$ROOT/scripts/darkmesh-migrate-agent" --apply \
    >"$TMP/apply.log" 2>&1; then
  echo "migration unexpectedly succeeded without a supervisor" >&2
  exit 1
fi
grep -q 'signed supervisor missing' "$TMP/apply.log" \
  || { echo "--apply was rejected before migration validation" >&2; exit 1; }
! grep -q '^Usage:' "$TMP/apply.log" \
  || { echo "--apply was rejected by argument parsing" >&2; exit 1; }

if SERVER_MONITOR_APP="$TMP/missing" bash "$ROOT/scripts/darkmesh-migrate-agent" --invalid \
    >"$TMP/invalid.log" 2>&1; then
  echo "invalid option unexpectedly succeeded" >&2
  exit 1
fi
grep -q '^Usage:' "$TMP/invalid.log" || { echo "invalid option did not report usage" >&2; exit 1; }

echo "PASS: migrate-agent accepts --apply and rejects invalid options"

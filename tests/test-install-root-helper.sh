#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t darkmesh-root-helper-test)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/payload/scripts" "$TMP/bin" "$TMP/links"
cp "$ROOT/scripts/install-root-helper.sh" "$TMP/payload/scripts/"
ln -s "../payload/scripts/install-root-helper.sh" "$TMP/bin/install-root-helper.sh"
ln -s "../bin/install-root-helper.sh" "$TMP/links/darkmesh-installer"

expected="$(cd -P "$TMP/payload/scripts" && pwd)"
direct="$(bash "$TMP/payload/scripts/install-root-helper.sh" --print-source-dir)"
relative="$(bash "$TMP/bin/install-root-helper.sh" --print-source-dir)"
chained="$(bash "$TMP/links/darkmesh-installer" --print-source-dir)"

[[ "$direct" == "$expected" ]] || {
  echo "direct invocation resolved to $direct, expected $expected" >&2
  exit 1
}
[[ "$relative" == "$expected" ]] || {
  echo "relative symlink resolved to $relative, expected $expected" >&2
  exit 1
}
[[ "$chained" == "$expected" ]] || {
  echo "symlink chain resolved to $chained, expected $expected" >&2
  exit 1
}

echo "PASS: root-helper installer resolves its packaged source through symlinks"

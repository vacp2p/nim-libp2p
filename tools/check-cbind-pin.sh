#!/usr/bin/env bash
# Nim-LibP2P
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
#
# Drift between the three cbind pin files makes the nimble and nix lanes build
# different dependency revisions, and both lanes stay green.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIMBLE_FILE="$REPO_ROOT/cbind/cbind.nimble"
LOCKFILE="$REPO_ROOT/cbind/nimble.lock"
DEPSFILE="$REPO_ROOT/nix/cbind-deps.nix"

command -v jq >/dev/null || { echo "error: jq required"; exit 1; }

for f in "$NIMBLE_FILE" "$LOCKFILE" "$DEPSFILE"; do
  [[ -f "$f" ]] || { echo "error: $f not found"; exit 1; }
done

mismatches=0

report() {
  echo "[!] $1"
  mismatches=$((mismatches + 1))
}

while read -r name url rev; do
  lock_url=$(jq -r --arg n "$name" '.packages[$n].url // empty' "$LOCKFILE")
  lock_rev=$(jq -r --arg n "$name" '.packages[$n].vcsRevision // empty' "$LOCKFILE")

  if [[ -z "$lock_rev" ]]; then
    report "$name is in nix/cbind-deps.nix but not in cbind/nimble.lock"
    continue
  fi
  [[ "$url" == "$lock_url" ]] ||
    report "$name url: nix/cbind-deps.nix has $url, cbind/nimble.lock has $lock_url"
  [[ "$rev" == "$lock_rev" ]] ||
    report "$name rev: nix/cbind-deps.nix has $rev, cbind/nimble.lock has $lock_rev"
done < <(awk '
  /^  [A-Za-z_][A-Za-z0-9_]* = pkgs\.fetchgit \{/ { name = $1; next }
  name && /url = / { url = $3; gsub(/[";]/, "", url); next }
  name && /rev = / { rev = $3; gsub(/[";]/, "", rev); print name, url, rev; name = "" }
' "$DEPSFILE")

# Direct Git URL requirements carry the revision inline: "<url>#<rev>".
while read -r url rev; do
  lock_rev=$(jq -r --arg u "$url" '.packages | to_entries[] | select(.value.url == $u) | .value.vcsRevision' "$LOCKFILE")
  if [[ -z "$lock_rev" ]]; then
    report "$url is required by cbind/cbind.nimble but not in cbind/nimble.lock"
    continue
  fi
  [[ "$rev" == "$lock_rev" ]] ||
    report "$url rev: cbind/cbind.nimble has $rev, cbind/nimble.lock has $lock_rev"
done < <(grep -oE '"https://[^"#]+#[0-9a-f]{40}"' "$NIMBLE_FILE" | tr -d '"' | awk -F'#' '{print $1, $2}')

if (( mismatches > 0 )); then
  echo "error: $mismatches pin mismatch(es); run 'make -C cbind deps' after 'nimble lock'"
  exit 1
fi

echo "[✓] cbind pins agree across cbind.nimble, nimble.lock and cbind-deps.nix"

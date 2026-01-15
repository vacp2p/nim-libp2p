#!/usr/bin/env bash
set -euo pipefail

LOCKFILE="nimble.lock"
VENDOR_DIR="vendor"

if ! command -v jq >/dev/null; then
  echo "error: jq is required"
  exit 1
fi

if [ ! -f "$LOCKFILE" ]; then
  echo "error: nimble.lock not found (run 'nimble lock')"
  exit 1
fi

mkdir -p "$VENDOR_DIR"

echo "[*] Vendoring dependencies from $LOCKFILE"

jq -c '
  .packages
  | to_entries[]
  | select(.value.downloadMethod == "git")
' "$LOCKFILE" | while read -r entry; do

  name=$(echo "$entry" | jq -r '.key')
  url=$(echo "$entry" | jq -r '.value.url')
  rev=$(echo "$entry" | jq -r '.value.vcsRevision')

  if [ -z "$url" ] || [ -z "$rev" ]; then
    echo "[!] skipping $name (missing url or revision)"
    continue
  fi

  if [[ ! "$rev" =~ ^[0-9a-f]{40}$ ]]; then
    echo "[!] skipping $name (invalid revision: $rev)"
    continue
  fi

  dest="$VENDOR_DIR/$name"

  if [ -d "$dest" ]; then
    echo "[=] $name already vendored"
    continue
  fi

  echo "[*] vendoring $name"
  echo "    url: $url"
  echo "    rev: $rev"

  git clone "$url" "$dest"
  ( cd "$dest" && git checkout "$rev" )

  # Remove VCS metadata for purity
  rm -rf "$dest/.git"
done

echo "[✓] Vendoring complete"


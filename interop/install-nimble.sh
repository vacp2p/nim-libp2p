#!/usr/bin/env bash
# Installs nimble into the interop Docker builder. `nimble install` exits 0 when the build
# of the package fails, and the clone of the submodules of nimble hits transient GitHub 503s.
set -euo pipefail

commit="${1:?usage: install-nimble.sh <commit>}"
bin="/root/.nimble/bin/nimble"
attempts=3

# The interop builds need `--resolver:minver`, which the nimble of the base image rejects.
installedWithResolver() {
  [ -x "$bin" ] && "$bin" --resolver:minver --version >/dev/null
}

rm -f "$bin"

attempt=1
while [ "$attempt" -le "$attempts" ]; do
  if [ "$attempt" -gt 1 ]; then
    sleep 15
  fi
  nimble install "nimble@#${commit}" -y || true
  if installedWithResolver; then
    exit 0
  fi
  echo "install-nimble: attempt ${attempt} of ${attempts} installed no usable ${bin}" >&2
  attempt=$((attempt + 1))
done

echo "install-nimble: cannot install nimble@#${commit}" >&2
exit 1

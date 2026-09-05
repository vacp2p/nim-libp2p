#!/usr/bin/env bash
# Cross-implementation interop runner for
# Noise_XXhfs_25519+ML-KEM-768_ChaChaPoly_SHA256 (/noise-mlkem768-hfs/0.1.0).
#
# Runs nim-libp2p against the JavaScript and Rust implementations of the same
# profile, in both roles where each side has a harness for it:
#
#   A  nim listener   <- js dialer
#   B  js listener    <- nim dialer   (+ post-handshake message exchange)
#   C  rust listener  <- nim dialer
#
# Point these at checkouts of the other implementations; a pair is skipped if
# its variable is unset.
#
#   JS_NOISE_DIR    js-libp2p-noise, branch feat/pqc-xxhfs-noise (PR #665),
#                   already built with `pnpm build`
#   RUST_LIBP2P_DIR rust-libp2p, branch feat/noise-mlkem-hfs, built with
#                   `cargo build -p libp2p-noise --example noise_hfs_listener \
#                       --features mlkem-hfs`
#
# Usage:
#   nim c -d:release --outdir:. interop_listen.nim
#   nim c -d:release --outdir:. interop_dial.nim
#   JS_NOISE_DIR=../../../js-libp2p-noise RUST_LIBP2P_DIR=../../../rust-libp2p \
#     bash interop_all.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LOGS="$HERE/logs"; rm -rf "$LOGS"; mkdir -p "$LOGS"

# Ports are arbitrary; 8000 is fixed by js-libp2p-noise's node-listener.mjs.
NIM_LISTEN_PORT=9101
JS_LISTEN_PORT=8000
RUST_LISTEN_PORT=9103
READY_TIMEOUT_TICKS=90   # 0.2 s per tick

PASS=0; FAIL=0; SKIP=0

# Nim emits .exe on Windows, a bare name elsewhere.
bin () {
  if [ -x "$HERE/$1.exe" ]; then echo "$HERE/$1.exe"
  elif [ -x "$HERE/$1" ]; then echo "$HERE/$1"
  else echo ""; fi
}

await_line () { # file pattern
  for _ in $(seq 1 $READY_TIMEOUT_TICKS); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

check () { # label file pattern
  if grep -q "$3" "$2" 2>/dev/null; then
    echo "  PASS  $1"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1"; FAIL=$((FAIL+1))
  fi
}

skip () { echo "  SKIP  $1 ($2)"; SKIP=$((SKIP+1)); }

NIM_LISTEN=$(bin interop_listen)
NIM_DIAL=$(bin interop_dial)
if [ -z "$NIM_LISTEN" ] || [ -z "$NIM_DIAL" ]; then
  echo "error: build the Nim binaries first (see usage in this file's header)" >&2
  exit 1
fi

echo "=== A  nim listener <- js dialer ==="
if [ -z "${JS_NOISE_DIR:-}" ]; then
  skip "A" "JS_NOISE_DIR unset"
else
  "$NIM_LISTEN" $NIM_LISTEN_PORT > "$LOGS/a_nim_listen.log" 2>&1 &
  if await_line "$LOGS/a_nim_listen.log" READY; then
    (cd "$JS_NOISE_DIR" && node scripts/noise-hfs-dial.mjs --port $NIM_LISTEN_PORT) \
      > "$LOGS/a_js_dial.log" 2>&1
    wait
    check "nim responder completed handshake" "$LOGS/a_nim_listen.log" HANDSHAKE_OK
    check "js initiator got remote peer id"   "$LOGS/a_js_dial.log" "^PEER "
  else
    check "nim listener became ready" "$LOGS/a_nim_listen.log" READY
    wait
  fi
fi

echo "=== B  js listener <- nim dialer (with data plane) ==="
if [ -z "${JS_NOISE_DIR:-}" ]; then
  skip "B" "JS_NOISE_DIR unset"
else
  (cd "$JS_NOISE_DIR" && node scripts/node-listener.mjs) > "$LOGS/b_js_listen.log" 2>&1 &
  JS_PID=$!
  if await_line "$LOGS/b_js_listen.log" "Listening on"; then
    "$NIM_DIAL" $JS_LISTEN_PORT --chat > "$LOGS/b_nim_dial.log" 2>&1
    await_line "$LOGS/b_js_listen.log" "INTEROP SUCCESS\|Unexpected reply" || true
    check "nim initiator completed handshake"   "$LOGS/b_nim_dial.log" HANDSHAKE_OK
    check "nim decrypted js transport frame"    "$LOGS/b_nim_dial.log" "RECV hello from JS"
    check "js decrypted nim transport frame"    "$LOGS/b_js_listen.log" "INTEROP SUCCESS"
  else
    check "js listener became ready" "$LOGS/b_js_listen.log" "Listening on"
  fi
  kill $JS_PID 2>/dev/null; wait 2>/dev/null
fi

echo "=== C  rust listener <- nim dialer ==="
if [ -z "${RUST_LIBP2P_DIR:-}" ]; then
  skip "C" "RUST_LIBP2P_DIR unset"
else
  RUST_BIN="$RUST_LIBP2P_DIR/target/debug/examples/noise_hfs_listener"
  [ -x "$RUST_BIN" ] || RUST_BIN="$RUST_BIN.exe"
  "$RUST_BIN" $RUST_LISTEN_PORT > "$LOGS/c_rs_listen.log" 2>&1 &
  if await_line "$LOGS/c_rs_listen.log" READY; then
    "$NIM_DIAL" $RUST_LISTEN_PORT > "$LOGS/c_nim_dial.log" 2>&1
    wait
    check "rust responder got remote peer id"  "$LOGS/c_rs_listen.log" "^PEER "
    check "nim initiator completed handshake"  "$LOGS/c_nim_dial.log" HANDSHAKE_OK
  else
    check "rust listener became ready" "$LOGS/c_rs_listen.log" READY
    wait
  fi
fi

echo
echo "=== $PASS passed, $FAIL failed, $SKIP skipped (logs in $LOGS) ==="
[ $FAIL -eq 0 ]

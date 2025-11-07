#!/bin/sh
set -eu

if [ -n "${NETEM:-}" ]; then
  tc qdisc add dev eth0 root netem $NETEM
fi

./quic
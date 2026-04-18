#!/bin/sh
set -eu

if [ -n "${NETEM:-}" ]; then
  tc qdisc replace dev eth0 root netem $NETEM
fi

./main

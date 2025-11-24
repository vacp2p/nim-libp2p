#!/usr/bin/env bash

LOG_DIR=${VALGRIND_LOG_DIR:-/node/vg-logs}
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/vg-${HOSTNAME:-node}.log"

for i in $(seq 1 2000); do
  echo "run $i (logging to $LOG_FILE)"
  valgrind \
    --tool=memcheck \
    --leak-check=full \
    --show-leak-kinds=all \
    --track-origins=yes \
    --num-callers=40 \
    --error-exitcode=99 \
    ./quic 2>"$LOG_FILE" && echo "ok" || break
done
#./quic
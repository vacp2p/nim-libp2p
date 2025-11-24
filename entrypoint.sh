#!/usr/bin/env bash

LOG_DIR=${VALGRIND_LOG_DIR:-/node/vg-logs}
mkdir -p "$LOG_DIR"

ls -la

LD_LIBRARY_PATH=".:${LD_LIBRARY_PATH}" HEAPPROFILE="$LOG_DIR/vg-${HOSTNAME:-node}.log" ./quic

cp ./quic $LOG_DIR/quic-${HOSTNAME:-node}
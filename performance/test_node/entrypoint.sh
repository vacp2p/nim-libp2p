#!/bin/sh
set -e

# Pre-execution hook
if [ -n "$PRE_EXEC_CMD" ]; then
  echo "[entrypoint] Running pre-execution command: $PRE_EXEC_CMD"
  eval "$PRE_EXEC_CMD"
fi

# Run main application
echo "[entrypoint] Starting main application..."
./main

# Post-execution hook
if [ -n "$POST_EXEC_CMD" ]; then
  echo "[entrypoint] Running post-execution command: $POST_EXEC_CMD"
  eval "$POST_EXEC_CMD"
fi

echo "[entrypoint] Completed"

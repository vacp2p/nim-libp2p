#!/bin/sh

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

set -eu

# Run before the harness command as well as before the wrapper starts Nim.
/usr/bin/hole-punch-router-nat

if [ "$#" -eq 0 ]; then
  set -- hole-punch-client
fi

exec "$@"

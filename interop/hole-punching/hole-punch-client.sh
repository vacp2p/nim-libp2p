#!/bin/sh

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

set -eu

# This is a harness compatibility wrapper; the real client is the Nim binary.
if ! /usr/bin/hole-punch-router-nat; then
  echo "hole-punch-router-nat failed; continuing" >&2
fi

exec /usr/bin/nim-hole-punch-client "$@"

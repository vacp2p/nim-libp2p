#!/bin/sh

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

set -eu

/usr/bin/hole-punch-client --fix-router-nat-only

if [ "$#" -eq 0 ]; then
  set -- hole-punch-client
fi

exec "$@"

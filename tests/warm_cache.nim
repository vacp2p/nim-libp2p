# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Compiles the libp2p library (and its heavy deps: chronos, crypto, transports)
## into the shared test nimcache without any tests, so CI's per-arch prebuild
## job can warm the cache once and every per-group test compile reuses the .o
## instead of rebuilding the library. Small enough to fit the 32-bit compiler.

import ../libp2p
export libp2p

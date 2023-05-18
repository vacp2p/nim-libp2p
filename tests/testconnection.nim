{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../libp2p/[stream/connection,
                  stream/bufferstream]

import ./helpers

suite "Connection":
  asyncTest "close":
    var conn = BufferStream.new()
    await conn.close()
    check:
      conn.closed == true

  asyncTest "parent close":
    var buf = BufferStream.new()
    var conn = buf

    await conn.close()
    check:
      conn.closed == true
      buf.closed == true

  asyncTest "child close":
    var buf = BufferStream.new()
    var conn = buf

    await buf.close()
    check:
      conn.closed == true
      buf.closed == true

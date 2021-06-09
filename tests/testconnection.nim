import chronos, nimcrypto/utils
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

{.used.}

# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ./helpers
import stew/byteutils
import ../../libp2p/stream/bridgestream

suite "BridgeStream":
  asyncTest "send-receive":
    let (c1, c2) = bridgedConnections()
    var msg: array[8, byte]

    # c1 -> c2
    await c1.write("hello c2")
    await c2.readExactly(addr msg, msg.len)
    check string.fromBytes(msg) == "hello c2"

    # c2 -> c1
    await c2.write("hello c1")
    await c1.readExactly(addr msg, msg.len)
    check string.fromBytes(msg) == "hello c1"

    await c1.close()
    await c2.close()

  asyncTest "closing":
    # closing c1, should also close c2
    var (c1, c2) = bridgedConnections()
    await c1.close()
    expect LPStreamEOFError:
      await c2.write("hello c1")

    # closing c2, should also close c1
    (c1, c2) = bridgedConnections()
    await c2.close()
    expect LPStreamEOFError:
      await c1.write("hello c2")

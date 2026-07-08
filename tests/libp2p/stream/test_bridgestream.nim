# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, stew/byteutils
import ../../../libp2p/stream/bridgestream
import ../../tools/[unittest]

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

  asyncTest "serializes concurrent writes to peer buffer":
    let (c1, c2) = bridgedConnections(serializeWrites = true)
    var msg: array[5, byte]

    await c1.write("first")

    let
      write1 = c1.write("again")
      write2 = c1.write("third")

    await c2.readExactly(addr msg, msg.len)
    check string.fromBytes(msg) == "first"
    await c2.readExactly(addr msg, msg.len)
    check string.fromBytes(msg) == "again"
    await c2.readExactly(addr msg, msg.len)
    check string.fromBytes(msg) == "third"

    check await allFutures(write1, write2).withTimeout(1.seconds)

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

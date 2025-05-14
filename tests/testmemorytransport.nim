{.used.}

# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import stew/byteutils
import ../libp2p/[transports/memorytransport, multiaddress]
import ./helpers

suite "Memory transport":
  teardown:
    checkTrackers()

  asyncTest "memory multiaddress":
    let ma = MultiAddress.init("/memory/addr-1").get()
    check $ma == "/memory/addr-1"

  asyncTest "can handle local address":
    let ma = @[MultiAddress.init("/memory/addr-1").get()]
    let transport: MemoryTransport = MemoryTransport.new()
    await transport.start(ma)
    check transport.handles(transport.addrs[0])
    await transport.stop()

  asyncTest "send receive":
    let ma = @[MultiAddress.init("/memory/addr-1").get()]
    let server = MemoryTransport.new()
    await server.start(ma)

    proc runClient() {.async.} =
      let client = MemoryTransport.new()
      let conn = await client.dial("", ma[0])

      await conn.write("client")
      var resp: array[6, byte]
      await conn.readExactly(addr resp, resp.len)
      await conn.close()

      check string.fromBytes(resp) == "server"
      await client.stop()

    proc serverAcceptHandler() {.async.} =
      let conn = await server.accept()
      var resp: array[6, byte]
      await conn.readExactly(addr resp, resp.len)
      check string.fromBytes(resp) == "client"

      await conn.write("server")
      await conn.close()
      await server.stop()

    asyncSpawn serverAcceptHandler()
    await runClient()

  asyncTest "server already started":
    let ma = @[MultiAddress.init("/memory/addr-1").get()]
    let server = MemoryTransport.new()
    await server.start(ma)

    proc serverAcceptHandler() {.async.} =
      let conn = await server.accept()
      await conn.close()

    asyncSpawn serverAcceptHandler()

    # accept by server2 should not succeed
    let server2 = MemoryTransport.new()
    await server2.start(ma)
    expect MemoryTransportError:
      discard await server2.accept()

    # dial to pass through server.accept()
    let conn = await server2.dial("", ma[0])
    await conn.close()

    await server.stop()
    await server2.stop()

  asyncTest "server stopping - should drop accept":
    let ma = @[MultiAddress.init("/memory/addr-1").get()]
    let server = MemoryTransport.new()
    await server.start(ma)

    proc serverAcceptHandler() {.async.} =
      # should throw error when stopped
      expect MemoryTransportAcceptStopped:
        discard await server.accept()

    asyncSpawn serverAcceptHandler()
    await server.stop()

  asyncTest "server conn close propagated to client":
    let ma = @[MultiAddress.init("/memory/addr-1").get()]
    let server = MemoryTransport.new()
    await server.start(ma)

    proc serverAcceptHandler() {.async.} =
      let conn = await server.accept()
      var resp: array[6, byte]
      await conn.readExactly(addr resp, resp.len)
      check string.fromBytes(resp) == "client"

      await conn.close()
      await server.stop()

    proc runClient() {.async.} =
      let client = MemoryTransport.new()
      let conn = await client.dial("", ma[0])

      await conn.write("client")
      var resp: array[6, byte]
      expect LPStreamEOFError:
        await conn.readExactly(addr resp, resp.len)

      await conn.close() # already closed
      await client.stop()

    asyncSpawn serverAcceptHandler()
    await runClient()

  asyncTest "client conn close propagated to server":
    let ma = @[MultiAddress.init("/memory/addr-1").get()]
    let server = MemoryTransport.new()
    await server.start(ma)

    proc serverAcceptHandler() {.async.} =
      let conn = await server.accept()
      expect LPStreamEOFError:
        await conn.write("server") # already closed

      await conn.close()
      await server.stop()

    proc runClient() {.async.} =
      let client = MemoryTransport.new()
      let conn = await client.dial("", ma[0])
      await conn.close()
      await client.stop()

    asyncSpawn serverAcceptHandler()
    await runClient()

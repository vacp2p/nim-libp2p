{.used.}

import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/wstransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers

suite "Websocket transport":
  #teardown:
  #  checkTrackers()

  asyncTest "test listener: handle write":
    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0/ws").tryGet()
    let transport: WsTransport = WsTransport.new(upgrade = Upgrade())
    asyncSpawn transport.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport.accept()
      await conn.write("Hello!")
      await conn.close()

    let handlerWait = acceptHandler()

    let streamTransport = await transport.dial(transport.ma)

    var buf: array[6, byte]
    await streamTransport.readExactly(addr buf[0], 6)

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await streamTransport.close()
    await transport.stop()
    check string.fromBytes(buf) == "Hello!"

  asyncTest "test listener: handle read":
    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0/ws").tryGet()

    let transport: WsTransport = WsTransport.new(upgrade = Upgrade())
    asyncSpawn transport.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      var msg = newSeq[byte](6)
      let conn = await transport.accept()
      await conn.readExactly(addr msg[0], 6)
      check string.fromBytes(msg) == "Hello!"
      await conn.close()

    let handlerWait = acceptHandler()
    let streamTransport = await transport.dial(transport.ma)
    await streamTransport.write("Hello!")

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await streamTransport.close()
    await transport.stop()

  asyncTest "e2e: handle write":
    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0/ws").tryGet()

    let transport1: WsTransport = WsTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport1.accept()
      await conn.write("Hello!")
      await conn.close()

    let handlerWait = acceptHandler()

    let transport2: WsTransport = WsTransport.new(upgrade = Upgrade())
    let conn = await transport2.dial(transport1.ma)
    var msg = newSeq[byte](6)
    await conn.readExactly(addr msg[0], 6)

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    await conn.close()
    await transport2.stop()
    await transport1.stop()

    check string.fromBytes(msg) == "Hello!"

  asyncTest "e2e: handle read":
    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0/ws").tryGet()
    let transport1: WsTransport = WsTransport.new(upgrade = Upgrade())
    asyncSpawn transport1.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport1.accept()
      var msg = newSeq[byte](6)
      await conn.readExactly(addr msg[0], 6)
      check string.fromBytes(msg) == "Hello!"
      await conn.close()

    let handlerWait = acceptHandler()

    let transport2: WsTransport = WsTransport.new(upgrade = Upgrade())
    let conn = await transport2.dial(transport1.ma)
    await conn.write("Hello!")

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    await conn.close()
    await transport2.stop()
    await transport1.stop()

  asyncTest "e2e: handle dial cancellation":
    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0/ws").tryGet()

    let transport1: WsTransport = WsTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    let transport2: WsTransport = WsTransport.new(upgrade = Upgrade())
    let cancellation = transport2.dial(transport1.ma)

    await cancellation.cancelAndWait()
    check cancellation.cancelled

    await transport2.stop()
    await transport1.stop()

  asyncTest "e2e: handle accept cancellation":
    let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0/ws").tryGet()

    let transport1: WsTransport = WsTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    let acceptHandler = transport1.accept()
    await acceptHandler.cancelAndWait()
    check acceptHandler.cancelled

    await transport1.stop()

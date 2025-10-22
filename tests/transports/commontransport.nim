{.used.}

import chronos, results, stew/byteutils
import
  ../../libp2p/
    [stream/connection, transports/transport, upgrademngrs/upgrade, multiaddress]

import ../helpers
import ./utils

template basicTransportTest*(
    provider: TransportBuilder, ma1: string, ma2: string = ""
) =
  block:
    let transportProvider = provider

    asyncTest "can handle local address":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let transport = transportProvider()
      await transport.start(ma)
      defer:
        await transport.stop()

      check transport.handles(transport.addrs[0])

    asyncTest "handle observedAddr":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()

      let acceptFut = server.accept()
      let clientConn = await client.dial(server.addrs[0])
      let serverConn = await acceptFut

      defer:
        await allFutures(clientConn.close(), serverConn.close())
        await allFutures(client.stop(), server.stop())

      # Tor transport doesn't provide observedAddr for privacy reasons
      if not isTorTransport(server.addrs[0]):
        check:
          server.handles(clientConn.observedAddr.get())
          client.handles(serverConn.observedAddr.get())

      check:
        # skip IP check, only check transport and port
        serverConn.localAddr.get()[3] == server.addrs[0][3]
        serverConn.localAddr.get()[4] == server.addrs[0][4]

    asyncTest "handle dial cancellation":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()
      defer:
        await allFutures(client.stop(), server.stop())

      let connFut = client.dial(server.addrs[0])
      await connFut.cancelAndWait()

      check connFut.cancelled

    asyncTest "handle accept cancellation":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      defer:
        await server.stop()

      let acceptFut = server.accept()
      await acceptFut.cancelAndWait()

      check acceptFut.cancelled

    asyncTest "stopping transport kills connections":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()

      let acceptFut = server.accept()
      let clientConn = await client.dial(server.addrs[0])
      let serverConn = await acceptFut

      await allFutures(client.stop(), server.stop())

      check:
        clientConn.closed()
        serverConn.closed()

    asyncTest "transport start/stop events":
      let ma = @[MultiAddress.init(ma1).tryGet()]
      let transport = transportProvider()

      await transport.start(ma)
      check await transport.onRunning.wait().withTimeout(1.seconds)

      await transport.stop()
      check await transport.onStop.wait().withTimeout(1.seconds)

template connectionTransportTest*(
    provider: TransportBuilder, ma1: string, ma2: string = ""
) =
  block:
    let transportProvider = provider

    asyncTest "e2e: handle write":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let transport1 = transportProvider()
      await transport1.start(ma)

      proc acceptHandler() {.async.} =
        let conn = await transport1.accept()
        await conn.write("Hello!")
        await conn.close()

      let handlerWait = acceptHandler()

      let transport2 = transportProvider()
      let conn = await transport2.dial(transport1.addrs[0])
      var msg = newSeq[byte](6)
      await conn.readExactly(addr msg[0], 6)

      await conn.close()
        #for some protocols, closing requires actively reading, so we must close here

      await allFuturesThrowing(allFinished(transport1.stop(), transport2.stop()))

      check string.fromBytes(msg) == "Hello!"
      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    asyncTest "e2e: handle read":
      let ma = @[MultiAddress.init(ma1).tryGet()]
      let transport1 = transportProvider()
      await transport1.start(ma)

      proc acceptHandler() {.async.} =
        let conn = await transport1.accept()
        var msg = newSeq[byte](6)
        await conn.readExactly(addr msg[0], 6)
        check string.fromBytes(msg) == "Hello!"
        await conn.close()

      let handlerWait = acceptHandler()

      let transport2 = transportProvider()
      let conn = await transport2.dial(transport1.addrs[0])
      await conn.write("Hello!")

      await conn.close()
        #for some protocols, closing requires actively reading, so we must close here
      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

      await allFuturesThrowing(allFinished(transport1.stop(), transport2.stop()))

    asyncTest "e2e should allow multiple local addresses":
      when defined(windows):
        # this randomly locks the Windows CI job
        skip()
        return
      let addrs =
        @[
          MultiAddress.init(ma1).tryGet(),
          MultiAddress.init(if ma2 == "": ma1 else: ma2).tryGet(),
        ]

      let transport1 = transportProvider()
      await transport1.start(addrs)

      proc acceptHandler() {.async, gensym.} =
        while true:
          let conn = await transport1.accept()
          await conn.write(newSeq[byte](0))
          await conn.write("Hello!")
          await conn.close()

      let handlerWait = acceptHandler()

      check transport1.addrs.len == 2
      check transport1.addrs[0] != transport1.addrs[1]

      var msg = newSeq[byte](6)

      proc client(ma: MultiAddress) {.async.} =
        let conn1 = await transport1.dial(ma)
        await conn1.readExactly(addr msg[0], 6)
        check string.fromBytes(msg) == "Hello!"
        await conn1.close()

      #Dial the same server multiple time in a row
      await client(transport1.addrs[0])
      await client(transport1.addrs[0])
      await client(transport1.addrs[0])

      #Dial the same server on different addresses
      await client(transport1.addrs[1])
      await client(transport1.addrs[0])
      await client(transport1.addrs[1])

      #Cancel a dial
      #TODO add back once chronos fixes cancellation
      #let
      #  dial1 = transport1.dial(transport1.addrs[1])
      #  dial2 = transport1.dial(transport1.addrs[0])
      #await dial1.cancelAndWait()
      #await dial2.cancelAndWait()

      await handlerWait.cancelAndWait()

      await transport1.stop()

    asyncTest "read or write on closed connection":
      let ma = @[MultiAddress.init(ma1).tryGet()]
      let transport1 = transportProvider()
      await transport1.start(ma)

      proc acceptHandler() {.async, gensym.} =
        let conn = await transport1.accept()
        await conn.close()

      let handlerWait = acceptHandler()

      let conn = await transport1.dial(transport1.addrs[0])

      var msg = newSeq[byte](6)
      expect LPStreamEOFError:
        await conn.readExactly(addr msg[0], 6)

      # we don't HAVE to throw on write on EOF
      # (at least TCP doesn't)
      try:
        await conn.write(msg)
      except LPStreamEOFError as exc:
        discard

      await conn.close()
        #for some protocols, closing requires actively reading, so we must close here
      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

      await transport1.stop()

{.used.}

import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers

type TransportProvider* = proc(): Transport {.gcsafe, raises: [Defect].}

proc commonTransportTest*(name: string, prov: TransportProvider, ma: string) =
  suite name & " common tests":
    teardown:
      checkTrackers()

    asyncTest "can handle local address":
      let ma = @[MultiAddress.init(ma).tryGet()]
      let transport1 = prov()
      await transport1.start(ma)
      check transport1.handles(transport1.addrs[0])
      await transport1.stop()

    asyncTest "e2e: handle observedAddr":
      let ma = @[MultiAddress.init(ma).tryGet()]

      let transport1 = prov()
      await transport1.start(ma)

      let transport2 = prov()

      proc acceptHandler() {.async, gcsafe.} =
        let conn = await transport1.accept()
        check transport1.handles(conn.observedAddr)
        await conn.close()

      let handlerWait = acceptHandler()

      let conn = await transport2.dial(transport1.addrs[0])

      check transport2.handles(conn.observedAddr)

      await conn.close() #for some protocols, closing requires actively reading, so we must close here

      await allFuturesThrowing(
        allFinished(
          transport1.stop(),
          transport2.stop()))

      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    asyncTest "e2e: handle write":
      let ma = @[MultiAddress.init(ma).tryGet()]

      let transport1 = prov()
      await transport1.start(ma)

      proc acceptHandler() {.async, gcsafe.} =
        let conn = await transport1.accept()
        await conn.write("Hello!")
        await conn.close()

      let handlerWait = acceptHandler()

      let transport2 = prov()
      let conn = await transport2.dial(transport1.addrs[0])
      var msg = newSeq[byte](6)
      await conn.readExactly(addr msg[0], 6)

      await conn.close() #for some protocols, closing requires actively reading, so we must close here

      await allFuturesThrowing(
        allFinished(
          transport1.stop(),
          transport2.stop()))

      check string.fromBytes(msg) == "Hello!"
      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    asyncTest "e2e: handle read":
      let ma = @[MultiAddress.init(ma).tryGet()]
      let transport1 = prov()
      await transport1.start(ma)

      proc acceptHandler() {.async, gcsafe.} =
        let conn = await transport1.accept()
        var msg = newSeq[byte](6)
        await conn.readExactly(addr msg[0], 6)
        check string.fromBytes(msg) == "Hello!"
        await conn.close()

      let handlerWait = acceptHandler()

      let transport2 = prov()
      let conn = await transport2.dial(transport1.addrs[0])
      await conn.write("Hello!")

      await conn.close() #for some protocols, closing requires actively reading, so we must close here
      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

      await allFuturesThrowing(
        allFinished(
          transport1.stop(),
          transport2.stop()))

    asyncTest "e2e: handle dial cancellation":
      let ma = @[MultiAddress.init(ma).tryGet()]

      let transport1 = prov()
      await transport1.start(ma)

      let transport2 = prov()
      let cancellation = transport2.dial(transport1.addrs[0])

      await cancellation.cancelAndWait()
      check cancellation.cancelled

      await allFuturesThrowing(
        allFinished(
          transport1.stop(),
          transport2.stop()))

    asyncTest "e2e: handle accept cancellation":
      let ma = @[MultiAddress.init(ma).tryGet()]

      let transport1 = prov()
      await transport1.start(ma)

      let acceptHandler = transport1.accept()
      await acceptHandler.cancelAndWait()
      check acceptHandler.cancelled

      await transport1.stop()

    asyncTest "e2e should allow multiple local addresses":
      when defined(windows):
        # this randomly locks the Windows CI job
        skip()
        return
      let addrs = @[MultiAddress.init(ma).tryGet(),
                    MultiAddress.init(ma).tryGet()]


      let transport1 = prov()
      await transport1.start(addrs)

      proc acceptHandler() {.async, gcsafe.} =
        while true:
          let conn = await transport1.accept()
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

    asyncTest "e2e: stopping transport kills connections":
      let ma = @[MultiAddress.init(ma).tryGet()]

      let transport1 = prov()
      await transport1.start(ma)

      let transport2 = prov()

      let acceptHandler = transport1.accept()
      let conn = await transport2.dial(transport1.addrs[0])
      let serverConn = await acceptHandler

      await allFuturesThrowing(
        allFinished(
          transport1.stop(),
          transport2.stop()))

      check serverConn.closed()
      check conn.closed()

    asyncTest "read or write on closed connection":
      let ma = @[MultiAddress.init(ma).tryGet()]
      let transport1 = prov()
      await transport1.start(ma)

      proc acceptHandler() {.async, gcsafe.} =
        let conn = await transport1.accept()
        await conn.close()

      let handlerWait = acceptHandler()

      let conn = await transport1.dial(transport1.addrs[0])

      var msg = newSeq[byte](6)
      try:
        await conn.readExactly(addr msg[0], 6)
        check false
      except CatchableError as exc:
        check true

      # we don't HAVE to throw on write on EOF
      # (at least TCP doesn't)
      try:
        await conn.write(msg)
      except CatchableError as exc:
        check true

      await conn.close() #for some protocols, closing requires actively reading, so we must close here
      await handlerWait.wait(1.seconds) # when no issues will not wait that long!

      await transport1.stop()

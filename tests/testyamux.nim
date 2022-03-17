
import chronos
import
  ../libp2p/[
    stream/connection,
    muxers/yamux/yamux
  ],
  ./helpers

suite "Yamux":
  teardown:
    checkTrackers()

  suite "E2E":
    asyncTest "Simple test":
      let
        (conna, connb) = bridgedConnections()
        (yamuxa, yamuxb) = (Yamux.new(conna), Yamux.new(connb))
        (handlera, handlerb) = (yamuxa.handle(), yamuxb.handle())
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.writeLp(fromHex("5678"))
        await conn.close()

      let streamA = await yamuxa.newStream()
      await streamA.writeLp(fromHex("1234"))
      check (await streamA.readLp(100)) == fromHex("5678")
      await streamA.close()

      await allFutures(
        conna.close(), connb.close(),
        yamuxa.close(), yamuxb.close(),
        handlera, handlerb)

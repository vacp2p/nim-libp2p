import chronos
import
  ../libp2p/[
    stream/connection,
    muxers/yamux/yamux
  ],
  ./helpers

suite "Yamux":
  #TODO failing right now
  #teardown:
  #  checkTrackers()

  template mSetup {.inject.} =
    #TODO in a template to avoid threadvar
    let
      (conna {.inject.}, connb {.inject.}) = bridgedConnections()
      (yamuxa {.inject.}, yamuxb {.inject.}) = (Yamux.new(conna), Yamux.new(connb))
      (handlera, handlerb) = (yamuxa.handle(), yamuxb.handle())

    defer:
      await allFutures(
        conna.close(), connb.close(),
        yamuxa.close(), yamuxb.close(),
        handlera, handlerb)

  suite "Basic":
    asyncTest "Simple test":
      mSetup()

      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.writeLp(fromHex("5678"))
        await conn.close()

      let streamA = await yamuxa.newStream()
      await streamA.writeLp(fromHex("1234"))
      check (await streamA.readLp(100)) == fromHex("5678")
      await streamA.close()

  suite "Window exhaustion":
    asyncTest "Basic exhaustion blocking":
      mSetup()
      let readerBlocker = newFuture[void]()
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await readerBlocker
        var buffer: array[160000, byte]
        discard await conn.readOnce(addr buffer[0], 160000)
        await conn.close()
      let streamA = await yamuxa.newStream()
      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](20))
      await sleepAsync(10.milliseconds)
      check: not secondWriter.finished()

      readerBlocker.complete()
      await wait(secondWriter, 1.seconds)

      await streamA.close()

    asyncTest "Exhaustion doesn't block other channels":
      mSetup()
      let readerBlocker = newFuture[void]()
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await readerBlocker
        var buffer: array[160000, byte]
        discard await conn.readOnce(addr buffer[0], 160000)
        await conn.close()
      let streamA = await yamuxa.newStream()
      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](20))
      await sleepAsync(10.milliseconds)

      # Now that the secondWriter is stuck, create a second stream
      # and exchange some data
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.writeLp(fromHex("5678"))
        await conn.close()

      let streamB = await yamuxa.newStream()
      await streamB.writeLp(fromHex("1234"))
      check (await streamB.readLp(100)) == fromHex("5678")
      check: not secondWriter.finished()
      readerBlocker.complete()

      await wait(secondWriter, 1.seconds)
      await streamA.close()
      await streamB.close()

    asyncTest "Can set custom window size":
      mSetup()

      let writerBlocker = newFuture[void]()
      var numberOfRead = 0
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        YamuxChannel(conn).setMaxRecvWindow(20)
        var buffer: array[256000, byte]
        while (await conn.readOnce(addr buffer[0], 256000)) > 0:
          numberOfRead.inc()
        writerBlocker.complete()
        await conn.close()
      let streamA = await yamuxa.newStream()
      # Need to exhaust initial window first
      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block
      await streamA.write(newSeq[byte](142))
      await streamA.close()

      await writerBlocker

      # 1 for initial exhaustion + (142 / 20) = 9
      check numberOfRead == 9

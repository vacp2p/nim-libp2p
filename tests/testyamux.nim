{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sugar
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

  template mSetup(ws: int = YamuxDefaultWindowSize,
                  inTo: Duration = 5.minutes,
                  outTo: Duration = 5.minutes) {.inject.} =
    #TODO in a template to avoid threadvar
    let
      (conna {.inject.}, connb {.inject.}) = bridgedConnections()
      yamuxa {.inject.} = Yamux.new(conna, windowSize = ws, inTimeout = inTo, outTimeout = outTo)
      yamuxb {.inject.} = Yamux.new(connb, windowSize = ws, inTimeout = inTo, outTimeout = outTo)
      (handlera, handlerb) = (yamuxa.handle(), yamuxb.handle())

    defer:
      await allFutures(
        conna.close(), connb.close(),
        yamuxa.close(), yamuxb.close(),
        handlera, handlerb)

  suite "Simple Reading/Writing yamux messages":
    asyncTest "Roundtrip of small messages":
      mSetup()

      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.writeLp(fromHex("5678"))
        await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.writeLp(fromHex("1234"))
      check (await streamA.readLp(100)) == fromHex("5678")
      await streamA.close()

    asyncTest "Continuing read after close":
      mSetup()
      let
        readerBlocker = newFuture[void]()
        handlerBlocker = newFuture[void]()
      var numberOfRead = 0
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await readerBlocker
        var buffer: array[25600, byte]
        while (await conn.readOnce(addr buffer[0], 25600)) > 0:
          numberOfRead.inc()
        await conn.close()
        handlerBlocker.complete()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block
      await streamA.close()
      readerBlocker.complete()
      await handlerBlocker
      check: numberOfRead == 10

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
      check streamA == yamuxa.getStreams()[0]

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
      check streamA == yamuxa.getStreams()[0]

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
      check streamA == yamuxa.getStreams()[0]

      # Need to exhaust initial window first
      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block
      await streamA.write(newSeq[byte](142))
      await streamA.close()

      await writerBlocker

      # 1 for initial exhaustion + (142 / 20) = 9
      check numberOfRead == 9

    asyncTest "Saturate until reset":
      mSetup()
      let writerBlocker = newFuture[void]()
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await writerBlocker
        var buffer: array[256, byte]
        check: (await conn.readOnce(addr buffer[0], 256)) == 0
        await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.write(newSeq[byte](256000))
      let wrFut = collect(newSeq):
        for _ in 0..3:
          streamA.write(newSeq[byte](100000))
      for i in 0..3:
        expect(LPStreamEOFError): await wrFut[i]
      writerBlocker.complete()
      await streamA.close()

    asyncTest "Increase window size":
      mSetup(512000)
      let readerBlocker = newFuture[void]()
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await readerBlocker
        var buffer: array[260000, byte]
        discard await conn.readOnce(addr buffer[0], 260000)
        await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](512000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](10000))
      await sleepAsync(10.milliseconds)
      check: not secondWriter.finished()

      readerBlocker.complete()
      await wait(secondWriter, 1.seconds)

      await streamA.close()

    asyncTest "Reduce window size":
      mSetup(64000)
      let readerBlocker1 = newFuture[void]()
      let readerBlocker2 = newFuture[void]()
      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await readerBlocker1
        var buffer: array[256000, byte]
        # For the first roundtrip, the send window size is assumed to be 256k
        discard await conn.readOnce(addr buffer[0], 256000)
        await readerBlocker2
        discard await conn.readOnce(addr buffer[0], 40000)

        await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](64000))
      await sleepAsync(10.milliseconds)
      check: not secondWriter.finished()

      readerBlocker1.complete()
      await wait(secondWriter, 1.seconds)

      let thirdWriter = streamA.write(newSeq[byte](10))
      await sleepAsync(10.milliseconds)
      check: not thirdWriter.finished()

      readerBlocker2.complete()
      await wait(thirdWriter, 1.seconds)
      await streamA.close()

  suite "Timeout testing":
    asyncTest "Check if InTimeout close both streams correctly":
      mSetup(inTo = 1.seconds)
      let blocker = newFuture[void]()
      let connBlocker = newFuture[void]()

      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.writeLp(fromHex("5678"))
        await blocker
        check conn.isClosed
        connBlocker.complete()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]
      await streamA.writeLp(fromHex("1234"))
      check (await streamA.readLp(100)) == fromHex("5678")
      # wait for the timeout to happens, the sleep duration is set to 4 seconds
      # as the timeout could be a bit long to trigger
      await sleepAsync(4.seconds)
      blocker.complete()
      check streamA.isClosed
      await connBlocker

    asyncTest "Check if OutTimeout close both streams correctly":
      mSetup(outTo = 1.seconds)
      let blocker = newFuture[void]()
      let connBlocker = newFuture[void]()

      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.writeLp(fromHex("5678"))
        await blocker
        check conn.isClosed
        connBlocker.complete()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]
      await streamA.writeLp(fromHex("1234"))
      check (await streamA.readLp(100)) == fromHex("5678")
      # wait for the timeout to happens, the sleep duration is set to 4 seconds
      # as the timeout could be a bit long to trigger
      await sleepAsync(4.seconds)
      blocker.complete()
      check streamA.isClosed
      await connBlocker

  suite "Exception testing":
    asyncTest "Local & Remote close":
      mSetup()

      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        check (await conn.readLp(100)) == fromHex("1234")
        await conn.close()
        expect LPStreamClosedError: await conn.writeLp(fromHex("102030"))
        check (await conn.readLp(100)) == fromHex("5678")

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.writeLp(fromHex("1234"))
      expect LPStreamRemoteClosedError: discard await streamA.readLp(100)
      await streamA.writeLp(fromHex("5678"))
      await streamA.close()

    asyncTest "Local & Remote reset":
      mSetup()
      let blocker = newFuture[void]()

      yamuxb.streamHandler = proc(conn: Connection) {.async.} =
        await blocker
        expect LPStreamResetError: discard await conn.readLp(100)
        expect LPStreamResetError: await conn.writeLp(fromHex("1234"))
        await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await yamuxa.close()
      expect LPStreamClosedError: await streamA.writeLp(fromHex("1234"))
      expect LPStreamClosedError: discard await streamA.readLp(100)
      blocker.complete()
      await streamA.close()

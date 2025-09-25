{.used.}

# Nim-Libp2p
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sugar
import chronos
import ../libp2p/[stream/connection, stream/bridgestream, muxers/yamux/yamux]
import ./helpers
import ./utils/futures

include ../libp2p/muxers/yamux/yamux

proc newBlockerFut(): Future[void] {.async: (raises: [], raw: true).} =
  newFuture[void]()

suite "Yamux":
  teardown:
    checkTrackers()

  template mSetup(
      ws: int = YamuxDefaultWindowSize,
      inTo: Duration = 5.minutes,
      outTo: Duration = 5.minutes,
      startHandlera = true,
      startHandlerb = true,
  ) {.inject.} =
    #TODO in a template to avoid threadvar
    let
      (conna {.inject.}, connb {.inject.}) = bridgedConnections(
        closeTogether = false, dirA = Direction.Out, dirB = Direction.In
      )
      yamuxa {.inject.} =
        Yamux.new(conna, windowSize = ws, inTimeout = inTo, outTimeout = outTo)
      yamuxb {.inject.} =
        Yamux.new(connb, windowSize = ws, inTimeout = inTo, outTimeout = outTo)
    var
      handlera = completedFuture()
      handlerb = completedFuture()

    if startHandlera:
      handlera = yamuxa.handle()
    if startHandlerb:
      handlerb = yamuxb.handle()

    defer:
      await allFutures(
        conna.close(), connb.close(), yamuxa.close(), yamuxb.close(), handlera, handlerb
      )

  suite "Simple Reading/Writing yamux messages":
    asyncTest "Roundtrip of small messages":
      mSetup()

      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          check (await conn.readLp(100)) == fromHex("1234")
          await conn.writeLp(fromHex("5678"))
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.writeLp(fromHex("1234"))
      check (await streamA.readLp(100)) == fromHex("5678")
      await streamA.close()

    asyncTest "Continuing read after close":
      mSetup()
      let
        readerBlocker = newBlockerFut()
        handlerBlocker = newBlockerFut()
      var numberOfRead = 0
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        await readerBlocker
        try:
          var buffer: array[25600, byte]
          while (await conn.readOnce(addr buffer[0], 25600)) > 0:
            numberOfRead.inc()
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()
        handlerBlocker.complete()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block
      await streamA.close()
      readerBlocker.complete()
      await handlerBlocker
      check:
        numberOfRead == 10

  suite "Window exhaustion":
    asyncTest "Basic exhaustion blocking":
      mSetup()
      let readerBlocker = newBlockerFut()
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        await readerBlocker
        try:
          var buffer: array[160000, byte]
          discard await conn.readOnce(addr buffer[0], 160000)
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](20))
      await sleepAsync(10.milliseconds)
      check:
        not secondWriter.finished()

      readerBlocker.complete()
      await wait(secondWriter, 1.seconds)

      await streamA.close()

    asyncTest "Exhaustion doesn't block other channels":
      mSetup()
      let readerBlocker = newBlockerFut()
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        await readerBlocker
        try:
          var buffer: array[160000, byte]
          discard await conn.readOnce(addr buffer[0], 160000)
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](20))
      await sleepAsync(10.milliseconds)

      # Now that the secondWriter is stuck, create a second stream
      # and exchange some data
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          check (await conn.readLp(100)) == fromHex("1234")
          await conn.writeLp(fromHex("5678"))
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamB = await yamuxa.newStream()
      await streamB.writeLp(fromHex("1234"))
      check (await streamB.readLp(100)) == fromHex("5678")
      check:
        not secondWriter.finished()
      readerBlocker.complete()

      await wait(secondWriter, 1.seconds)
      await streamA.close()
      await streamB.close()

    asyncTest "Can set custom window size":
      mSetup()

      let writerBlocker = newBlockerFut()
      var numberOfRead = 0
      const newWindow = 20
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        YamuxChannel(conn).setMaxRecvWindow(newWindow)
        try:
          var buffer: array[256000, byte]
          while (await conn.readOnce(addr buffer[0], 256000)) > 0:
            numberOfRead.inc()
          writerBlocker.complete()
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      # Need to exhaust initial window first
      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block
      const extraBytes = 160
      await streamA.write(newSeq[byte](extraBytes))
      await streamA.close()

      await writerBlocker

      # 1 for initial exhaustion + (160 / 20) = 9
      check numberOfRead == 1 + (extraBytes / newWindow).int

    asyncTest "Saturate until reset":
      mSetup()
      let writerBlocker = newBlockerFut()
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        await writerBlocker
        try:
          var buffer: array[256, byte]
          check:
            (await conn.readOnce(addr buffer[0], 256)) == 0
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.write(newSeq[byte](256000))
      let wrFut = collect(newSeq):
        for _ in 0 .. 3:
          streamA.write(newSeq[byte](100000))
      for i in 0 .. 3:
        expect(LPStreamEOFError):
          await wrFut[i]
      writerBlocker.complete()
      await streamA.close()

    asyncTest "Increase window size":
      mSetup(512000)
      let readerBlocker = newBlockerFut()
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        await readerBlocker
        try:
          var buffer: array[260000, byte]
          discard await conn.readOnce(addr buffer[0], 260000)
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](512000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](10000))
      await sleepAsync(10.milliseconds)
      check:
        not secondWriter.finished()

      readerBlocker.complete()
      await wait(secondWriter, 1.seconds)

      await streamA.close()

    asyncTest "Reduce window size":
      mSetup(64000)
      let readerBlocker1 = newBlockerFut()
      let readerBlocker2 = newBlockerFut()
      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          await readerBlocker1
          var buffer: array[256000, byte]
          # For the first roundtrip, the send window size is assumed to be 256k
          discard await conn.readOnce(addr buffer[0], 256000)
          await readerBlocker2
          discard await conn.readOnce(addr buffer[0], 40000)
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await wait(streamA.write(newSeq[byte](256000)), 1.seconds) # shouldn't block

      let secondWriter = streamA.write(newSeq[byte](64000))
      await sleepAsync(10.milliseconds)
      check:
        not secondWriter.finished()

      readerBlocker1.complete()
      await wait(secondWriter, 1.seconds)

      let thirdWriter = streamA.write(newSeq[byte](10))
      await sleepAsync(10.milliseconds)
      check:
        not thirdWriter.finished()

      readerBlocker2.complete()
      await wait(thirdWriter, 1.seconds)
      await streamA.close()

  suite "Timeout testing":
    asyncTest "Check if InTimeout close both streams correctly":
      mSetup(inTo = 1.seconds)
      let blocker = newBlockerFut()
      let connBlocker = newBlockerFut()

      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          check (await conn.readLp(100)) == fromHex("1234")
          await conn.writeLp(fromHex("5678"))
          await blocker
          check conn.isClosed
          connBlocker.complete()
        except CancelledError, LPStreamError:
          await conn.close()

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
      let blocker = newBlockerFut()
      let connBlocker = newBlockerFut()

      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          check (await conn.readLp(100)) == fromHex("1234")
          await conn.writeLp(fromHex("5678"))
          await blocker
          check conn.isClosed
          connBlocker.complete()
        except CancelledError, LPStreamError:
          await conn.close()

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

      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          check (await conn.readLp(100)) == fromHex("1234")
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()
        expect LPStreamClosedError:
          await conn.writeLp(fromHex("102030"))
        try:
          check (await conn.readLp(100)) == fromHex("5678")
        except CancelledError, LPStreamError:
          return

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.writeLp(fromHex("1234"))
      expect LPStreamRemoteClosedError:
        discard await streamA.readLp(100)
      await streamA.writeLp(fromHex("5678"))
      await streamA.close()

    asyncTest "Local & Remote reset":
      mSetup()
      let blocker = newBlockerFut()

      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        await blocker
        try:
          expect LPStreamResetError:
            discard await conn.readLp(100)
          expect LPStreamResetError:
            await conn.writeLp(fromHex("1234"))
        except CancelledError, LPStreamError:
          return
        finally:
          await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await yamuxa.close()
      expect LPStreamClosedError:
        await streamA.writeLp(fromHex("1234"))
      expect LPStreamClosedError:
        discard await streamA.readLp(100)
      blocker.complete()
      await streamA.close()

    asyncTest "Peer must be able to read from stream after closing it for writing":
      mSetup()

      yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
        try:
          check (await conn.readLp(100)) == fromHex("1234")
        except CancelledError, LPStreamError:
          return
        try:
          await conn.writeLp(fromHex("5678"))
        except CancelledError, LPStreamError:
          return
        await conn.close()

      let streamA = await yamuxa.newStream()
      check streamA == yamuxa.getStreams()[0]

      await streamA.writeLp(fromHex("1234"))
      await streamA.close()
      check (await streamA.readLp(100)) == fromHex("5678")

  suite "Frame handling and stream initiation":
    asyncTest "Ping Syn responds Ping Ack":
      mSetup(startHandlera = false)

      let payload: uint32 = 0x12345678'u32
      await conna.write(YamuxHeader.ping(MsgFlags.Syn, payload))

      let header = await conna.readHeader()
      check:
        header.msgType == Ping
        header.flags == {Ack}
        header.length == payload

    asyncTest "Go Away Status responds with Go Away":
      mSetup(startHandlera = false)

      await conna.write(YamuxHeader.goAway(GoAwayStatus.ProtocolError))

      let header = await conna.readHeader()
      check:
        header.msgType == GoAway
        header.flags == {}
        header.length == GoAwayStatus.NormalTermination.uint32

    for testCase in [
      YamuxHeader.data(streamId = 1'u32, length = 0, {Syn}),
      YamuxHeader.windowUpdate(streamId = 5'u32, delta = 0, {Syn}),
    ]:
      asyncTest "Syn opens stream and sends Ack - " & $testCase:
        mSetup(startHandlera = false)

        yamuxb.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
          try:
            await conn.close()
          except CancelledError, LPStreamError:
            return

        await conna.write(testCase)

        let ackHeader = await conna.readHeader()
        check:
          ackHeader.msgType == WindowUpdate
          ackHeader.streamId == testCase.streamId
          ackHeader.flags == {Ack}

        check:
          yamuxb.channels.hasKey(testCase.streamId)
          yamuxb.channels[testCase.streamId].opened

        let finHeader = await conna.readHeader()
        check:
          finHeader.msgType == Data
          finHeader.streamId == testCase.streamId
          finHeader.flags == {Fin}

    for badHeader in [
      # Reserved parity on Data+Syn (even id against responder)
      YamuxHeader.data(streamId = 2'u32, length = 0, {Syn}),
      # Reserved stream id 0
      YamuxHeader.data(streamId = 0'u32, length = 0, {Syn}),
      # Reserved parity on WindowUpdate+Syn (even id against responder)
      YamuxHeader.windowUpdate(streamId = 4'u32, delta = 0, {Syn}),
    ]:
      asyncTest "Reject invalid/unknown header - " & $badHeader:
        mSetup(startHandlera = false)

        await conna.write(badHeader)

        let header = await conna.readHeader()
        check:
          header.msgType == GoAway
          header.flags == {}
          header.length == GoAwayStatus.ProtocolError.uint32
          not yamuxb.channels.hasKey(badHeader.streamId)

    asyncTest "Flush unknown-stream Data up to budget then ProtocolError when exceeded":
      # Cover the flush path: streamId not in channels, no Syn, with a pre-seeded
      # flush budget in yamuxb.flushed. First frame should be flushed (no GoAway),
      # second frame exceeding the remaining budget should trigger ProtocolError.
      mSetup(startHandlera = false)

      let streamId = 11'u32
      yamuxb.flushed[streamId] = 4 # allow up to 4 bytes to be flushed

      # 1) Send a Data frame (no Syn) with length=3 and a 3-byte payload -> should be flushed.
      await conna.write(YamuxHeader.data(streamId = streamId, length = 3))
      await conna.write(fromHex("010203"))

      # 2) Send another Data frame with length=2 (remaining budget is 1) -> exceeds, expect GoAway.
      await conna.write(YamuxHeader.data(streamId = streamId, length = 2))
      await conna.write(fromHex("0405"))

      let header = await conna.readHeader()
      check:
        header.msgType == GoAway
        header.flags == {}
        header.length == GoAwayStatus.ProtocolError.uint32

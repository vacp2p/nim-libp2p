import unittest, strformat, strformat, random
import chronos, nimcrypto/utils, chronicles
import ../libp2p/[errors,
                  stream/connection,
                  stream/bufferstream,
                  transports/tcptransport,
                  transports/transport,
                  multiaddress,
                  muxers/mplex/mplex,
                  muxers/mplex/coder,
                  muxers/mplex/types,
                  muxers/mplex/lpchannel,
                  vbuffer,
                  varint]

import ./helpers

when defined(nimHasUsed): {.used.}

suite "Mplex":
  teardown:
    for tracker in testTrackers():
      echo tracker.dump()
      check tracker.isLeaked() == false

  test "encode header with channel id 0":
    proc testEncodeHeader() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("000873747265616d2031")

      let conn = newBufferStream(encHandler)
      await conn.writeMsg(0, MessageType.New, cast[seq[byte]]("stream 1"))
      await conn.close()

    waitFor(testEncodeHeader())

  test "encode header with channel id other than 0":
    proc testEncodeHeader() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("88010873747265616d2031")

      let conn = newBufferStream(encHandler)
      await conn.writeMsg(17, MessageType.New, cast[seq[byte]]("stream 1"))
      await conn.close()

    waitFor(testEncodeHeader())

  test "encode header and body with channel id 0":
    proc testEncodeHeaderBody() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("020873747265616d2031")

      let conn = newBufferStream(encHandler)
      await conn.writeMsg(0, MessageType.MsgOut, cast[seq[byte]]("stream 1"))
      await conn.close()

    waitFor(testEncodeHeaderBody())

  test "encode header and body with channel id other than 0":
    proc testEncodeHeaderBody() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("8a010873747265616d2031")

      let conn = newBufferStream(encHandler)
      await conn.writeMsg(17, MessageType.MsgOut, cast[seq[byte]]("stream 1"))
      await conn.close()

    waitFor(testEncodeHeaderBody())

  test "decode header with channel id 0":
    proc testDecodeHeader() {.async.} =
      let conn = newBufferStream()
      await conn.pushTo(fromHex("000873747265616d2031"))
      let msg = await conn.readMsg()

      check msg.id == 0
      check msg.msgType == MessageType.New
      await conn.close()

    waitFor(testDecodeHeader())

  test "decode header and body with channel id 0":
    proc testDecodeHeader() {.async.} =
      let conn = newBufferStream()
      await conn.pushTo(fromHex("021668656C6C6F2066726F6D206368616E6E656C20302121"))
      let msg = await conn.readMsg()

      check msg.id == 0
      check msg.msgType == MessageType.MsgOut
      check cast[string](msg.data) == "hello from channel 0!!"
      await conn.close()

    waitFor(testDecodeHeader())

  test "decode header and body with channel id other than 0":
    proc testDecodeHeader() {.async.} =
      let conn = newBufferStream()
      await conn.pushTo(fromHex("8a011668656C6C6F2066726F6D206368616E6E656C20302121"))
      let msg = await conn.readMsg()

      check msg.id == 17
      check msg.msgType == MessageType.MsgOut
      check cast[string](msg.data) == "hello from channel 0!!"
      await conn.close()

    waitFor(testDecodeHeader())

  test "half closed - channel should close for write":
    proc testClosedForWrite() {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        conn = newBufferStream(writeHandler)
        chann = newChannel(1, conn, true)
      try:
        await chann.close()
        await chann.write("Hello")
      finally:
        await chann.reset()
        await conn.close()

    expect LPStreamClosedError:
      waitFor(testClosedForWrite())

  test "half closed - channel should close for read by remote":
    proc testClosedForRead() {.async.} =
      let
        conn = newBufferStream(
          proc (data: seq[byte]) {.gcsafe, async.} =
            result = nil
        )
        chann = newChannel(1, conn, true)

      try:
        await chann.pushTo(cast[seq[byte]]("Hello!"))
        let closeFut = chann.closeRemote()

        var data = newSeq[byte](6)
        await chann.readExactly(addr data[0], 6) # this should work, since there is data in the buffer
        await chann.readExactly(addr data[0], 6) # this should throw
        await closeFut
      finally:
        await chann.close()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testClosedForRead())

  test "should not allow pushing data to channel when remote end closed":
    proc testResetWrite() {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        conn = newBufferStream(writeHandler)
        chann = newChannel(1, conn, true)
      try:
        await chann.closeRemote()
        await chann.pushTo(@[byte(1)])
      finally:
        await chann.close()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testResetWrite())

  # test "reset - channel should fail reading":
  #   proc testResetRead(): Future[void] {.async.} =
  #     proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
  #     let
  #       conn = newBufferStream(writeHandler)
  #       chann = newChannel(1, conn, true)

  #     try:
  #       await chann.reset()
  #       var data = newSeq[byte](1)
  #       await chann.readExactly(addr data[0], 1)
  #       doAssert(len(data) == 1)
  #     finally:
  #       await conn.close()

  #   expect LPStreamEOFError:
  #     waitFor(testResetRead())

  # test "reset - channel should fail writing":
  #   proc testResetWrite(): Future[void] {.async.} =
  #     proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
  #     let
  #       conn = newBufferStream(writeHandler)
  #       chann = newChannel(1, conn, true)
  #     try:
  #       await chann.reset()
  #       await chann.write(cast[seq[byte]]("Hello!"))
  #     finally:
  #       await conn.close()

  #   expect LPStreamEOFError:
  #     waitFor(testResetWrite())

  # test "read/write receiver":
  #   proc testNewStream() {.async.} =
  #     let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

  #     var
  #       done = newFuture[void]()
  #       conn1 = newBufferStream()
  #       conn2 = newBufferStream()

  #     conn1 = conn1 | conn2 | conn1
  #     var listenHandler: Future[void]
  #     let mplexListen = newMplex(conn2)
  #     mplexListen.streamHandler = proc(stream: Connection) {.async, gcsafe.} =
  #       let msg = await stream.readLp(1024)
  #       check cast[string](msg) == "HELLO"
  #       await stream.close()
  #       done.complete()

  #     listenHandler = mplexListen.handle()

  #     var dialHandler: Future[void]
  #     let mplexDial = newMplex(conn1)
  #     dialHandler = mplexDial.handle()
  #     let stream = await mplexDial.newStream()
  #     await stream.writeLp("HELLO")
  #     await stream.close()

  #     # bufferstreams aren't half closed,
  #     # so we need to give them some time
  #     # to properly pipe data
  #     await allFuturesThrowing(conn1.close(), conn2.close())
  #     await done.wait(1.seconds)
  #     await allFuturesThrowing(listenHandler, dialHandler)

  #   waitFor(testNewStream())

  test "e2e - read/write receiver":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == "HELLO"
          await stream.close()
          done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let lfut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      let stream = await mplexDial.newStream()
      let openState = cast[LPChannel](stream).isOpen
      await stream.writeLp("HELLO")
      await stream.close()
      check openState # not lazy

      await done.wait(1.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await lfut

    waitFor(testNewStream())

  test "e2e - read/write receiver lazy":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == "HELLO"
          await stream.close()
          done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream(lazy = true)
      let mplexDialFut = mplexDial.handle()
      let openState = cast[LPChannel](stream).isOpen
      await stream.writeLp("HELLO")
      await stream.close()

      check not openState # assert lazy

      await done.wait(1.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - write fragmented":
    proc testNewStream() {.async.} =
      let
        ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
        listenJob = newFuture[void]()

      var bigseq = newSeqOfCap[uint8](MaxMsgSize * 2)
      for _ in 0..<MaxMsgSize:
        bigseq.add(uint8(rand(uint('A')..uint('z'))))

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(MaxMsgSize)
          check msg == bigseq
          trace "Bigseq check passed!"
          await stream.close()
          listenJob.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream()

      await stream.writeLp(bigseq)
      try:
        await listenJob.wait(10.seconds)
      except AsyncTimeoutError:
        check false

      await stream.close()
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - read/write initiator":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          await stream.writeLp("Hello from stream!")
          await stream.close()
          done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream("DIALER")
      let msg = cast[string](await stream.readLp(1024))
      await stream.close()
      check msg == "Hello from stream!"

      await done.wait(1.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - multiple streams":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        var count = 1
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == &"stream {count}!"
          await stream.close()
          count.inc
          if count == 10:
            done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1 = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      for i in 1..10:
        let stream  = await mplexDial.newStream()
        await stream.writeLp(&"stream {i}!")
        await stream.close()

      await done.wait(10.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - multiple read/write streams":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        var count = 1
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == &"stream {count} from dialer!"
          await stream.writeLp(&"stream {count} from listener!")
          count.inc
          await stream.close()
          if count == 10:
            done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      for i in 1..10:
        let stream  = await mplexDial.newStream("dialer stream")
        await stream.writeLp(&"stream {i} from dialer!")
        let msg = await stream.readLp(1024)
        check cast[string](msg) == &"stream {i} from listener!"
        await stream.close()

      await done.wait(5.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "jitter - channel should be able to handle erratic read/writes":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var complete = newFuture[void]()
      const MsgSize = 1024
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(MsgSize)
          check msg.len == MsgSize
          await stream.close()
          complete.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      let stream = await mplexDial.newStream()
      var bigseq = newSeqOfCap[uint8](MaxMsgSize + 1)
      for _ in 0..<MsgSize: # write one less than max size
        bigseq.add(uint8(rand(uint('A')..uint('z'))))

      ## create lenght prefixed libp2p frame
      var buf = initVBuffer()
      buf.writeSeq(bigseq)
      buf.finish()

      ## create mplex header
      var mplexBuf = initVBuffer()
      mplexBuf.writePBVarint((1.uint shl 3) or ord(MessageType.MsgOut).uint)
      mplexBuf.writePBVarint(buf.buffer.len.uint) # size should be always sent

      await conn.write(mplexBuf.buffer)
      proc writer() {.async.} =
        var sent = 0
        randomize()
        let total = buf.buffer.len
        const min = 20
        const max = 50
        while sent < total:
          var size = rand(min..max)
          size = if size > buf.buffer.len: buf.buffer.len else: size
          var send = buf.buffer[0..<size]
          await conn.write(send)
          sent += size
          buf.buffer = buf.buffer[size..^1]

      await writer()

      await stream.close()
      await conn.close()
      await complete.wait(1.seconds)
      await mplexDialFut

      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(test())

  test "jitter - channel should handle 1 byte read/write":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var complete = newFuture[void]()
      const MsgSize = 512
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(MsgSize)
          check msg.len == MsgSize
          await stream.close()
          complete.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream()
      let mplexDialFut = mplexDial.handle()
      var bigseq = newSeqOfCap[uint8](MsgSize + 1)
      for _ in 0..<MsgSize: # write one less than max size
        bigseq.add(uint8(rand(uint('A')..uint('z'))))

      ## create lenght prefixed libp2p frame
      var buf = initVBuffer()
      buf.writeSeq(bigseq)
      buf.finish()

      ## create mplex header
      var mplexBuf = initVBuffer()
      mplexBuf.writePBVarint((1.uint shl 3) or ord(MessageType.MsgOut).uint)
      mplexBuf.writePBVarint(buf.buffer.len.uint) # size should be always sent

      await conn.write(mplexBuf.buffer)
      proc writer() {.async.} =
        for i in buf.buffer:
          await conn.write(@[i])

      await writer()

      await complete.wait(5.seconds)
      await stream.close()
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(transport1.close(), transport2.close())
      await listenFut

    waitFor(test())

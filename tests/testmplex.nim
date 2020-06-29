import unittest, strformat, strformat, random
import chronos, nimcrypto/utils, chronicles, stew/byteutils
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
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "encode header with channel id 0":
    proc testEncodeHeader() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("000873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = stream
      await conn.writeMsg(0, MessageType.New, ("stream 1").toBytes)
      await conn.close()

    waitFor(testEncodeHeader())

  test "encode header with channel id other than 0":
    proc testEncodeHeader() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("88010873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = stream
      await conn.writeMsg(17, MessageType.New, ("stream 1").toBytes)
      await conn.close()

    waitFor(testEncodeHeader())

  test "encode header and body with channel id 0":
    proc testEncodeHeaderBody() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("020873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = stream
      await conn.writeMsg(0, MessageType.MsgOut, ("stream 1").toBytes)
      await conn.close()

    waitFor(testEncodeHeaderBody())

  test "encode header and body with channel id other than 0":
    proc testEncodeHeaderBody() {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("8a010873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = stream
      await conn.writeMsg(17, MessageType.MsgOut, ("stream 1").toBytes)
      await conn.close()

    waitFor(testEncodeHeaderBody())

  test "decode header with channel id 0":
    proc testDecodeHeader() {.async.} =
      let stream = newBufferStream()
      let conn = stream
      await stream.pushTo(fromHex("000873747265616d2031"))
      let msg = await conn.readMsg()

      check msg.id == 0
      check msg.msgType == MessageType.New
      await conn.close()

    waitFor(testDecodeHeader())

  test "decode header and body with channel id 0":
    proc testDecodeHeader() {.async.} =
      let stream = newBufferStream()
      let conn = stream
      await stream.pushTo(fromHex("021668656C6C6F2066726F6D206368616E6E656C20302121"))
      let msg = await conn.readMsg()

      check msg.id == 0
      check msg.msgType == MessageType.MsgOut
      check string.fromBytes(msg.data) == "hello from channel 0!!"
      await conn.close()

    waitFor(testDecodeHeader())

  test "decode header and body with channel id other than 0":
    proc testDecodeHeader() {.async.} =
      let stream = newBufferStream()
      let conn = stream
      await stream.pushTo(fromHex("8a011668656C6C6F2066726F6D206368616E6E656C20302121"))
      let msg = await conn.readMsg()

      check msg.id == 17
      check msg.msgType == MessageType.MsgOut
      check string.fromBytes(msg.data) == "hello from channel 0!!"
      await conn.close()

    waitFor(testDecodeHeader())

  test "half closed - channel should close for write":
    proc testClosedForWrite(): Future[bool] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        conn = newBufferStream(writeHandler)
        chann = newChannel(1, conn, true)
      await chann.close()
      try:
        await chann.write("Hello")
      except LPStreamClosedError:
        result = true
      finally:
        await chann.reset()
        await conn.close()

    check:
      waitFor(testClosedForWrite()) == true

  test "half closed - channel should close for read by remote":
    proc testClosedForRead(): Future[bool] {.async.} =
      let
        conn = newBufferStream(
          proc (data: seq[byte]) {.gcsafe, async.} =
            result = nil
        )
        chann = newChannel(1, conn, true)

      await chann.pushTo(("Hello!").toBytes)
      let closeFut = chann.closeRemote()

      var data = newSeq[byte](6)
      await chann.readExactly(addr data[0], 6) # this should work, since there is data in the buffer
      try:
        await chann.readExactly(addr data[0], 6) # this should throw
        await closeFut
      except LPStreamEOFError:
        result = true
      finally:
        await chann.close()
        await conn.close()

    check:
      waitFor(testClosedForRead()) == true

  test "should not allow pushing data to channel when remote end closed":
    proc testResetWrite(): Future[bool] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        conn = newBufferStream(writeHandler)
        chann = newChannel(1, conn, true)
      await chann.closeRemote()
      try:
        await chann.pushTo(@[byte(1)])
      except LPStreamEOFError:
        result = true
      finally:
        await chann.close()
        await conn.close()

    check:
      waitFor(testResetWrite()) == true

  test "reset - channel should fail reading":
    proc testResetRead(): Future[bool] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        conn = newBufferStream(writeHandler)
        chann = newChannel(1, conn, true)

      await chann.reset()
      var data = newSeq[byte](1)
      try:
        await chann.readExactly(addr data[0], 1)
        check data.len == 1
      except LPStreamEOFError:
        result = true
      finally:
        await conn.close()

    check:
      waitFor(testResetRead()) == true

  test "reset - channel should fail writing":
    proc testResetWrite(): Future[bool] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        conn = newBufferStream(writeHandler)
        chann = newChannel(1, conn, true)
      await chann.reset()
      try:
        await chann.write(("Hello!").toBytes)
      except LPStreamClosedError:
        result = true
      finally:
        await conn.close()

    check:
      waitFor(testResetWrite()) == true

  test "e2e - read/write receiver":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      var done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check string.fromBytes(msg) == "HELLO"
          await stream.close()
          done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      let stream = await mplexDial.newStream()
      await stream.writeLp("HELLO")
      check LPChannel(stream).isOpen # not lazy
      await stream.close()

      await done.wait(1.seconds)
      await conn.close()
      await mplexDialFut.wait(1.seconds)
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - read/write receiver lazy":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      var done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check string.fromBytes(msg) == "HELLO"
          await stream.close()
          done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream(lazy = true)
      let mplexDialFut = mplexDial.handle()
      check not LPChannel(stream).isOpen # assert lazy
      await stream.writeLp("HELLO")
      check LPChannel(stream).isOpen # assert lazy
      await stream.close()

      await done.wait(1.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - write fragmented":
    proc testNewStream() {.async.} =
      let
        ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
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

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
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
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - read/write initiator":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

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

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream("DIALER")
      let msg = string.fromBytes(await stream.readLp(1024))
      await stream.close()
      check msg == "Hello from stream!"

      await done.wait(1.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - multiple streams":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      let done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        var count = 1
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check string.fromBytes(msg) == &"stream {count}!"
          count.inc
          await stream.close()
          if count == 10:
            done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1 = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      # TODO: Reenable once half-closed is working properly
      let mplexDialFut = mplexDial.handle()
      for i in 1..10:
        let stream  = await mplexDial.newStream()
        await stream.writeLp(&"stream {i}!")
        await stream.close()

      await done.wait(10.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "e2e - multiple read/write streams":
    proc testNewStream() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      let done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        var count = 1
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = proc(stream: Connection)
          {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check string.fromBytes(msg) == &"stream {count} from dialer!"
          await stream.writeLp(&"stream {count} from listener!")
          count.inc
          await stream.close()
          if count == 10:
            done.complete()

        await mplexListen.handle()
        await mplexListen.close()

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let mplexDialFut = mplexDial.handle()
      for i in 1..10:
        let stream  = await mplexDial.newStream("dialer stream")
        await stream.writeLp(&"stream {i} from dialer!")
        let msg = await stream.readLp(1024)
        check string.fromBytes(msg) == &"stream {i} from listener!"
        await stream.close()

      await done.wait(5.seconds)
      await conn.close()
      await mplexDialFut
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(testNewStream())

  test "jitter - channel should be able to handle erratic read/writes":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

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

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
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

      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(test())

  test "jitter - channel should handle 1 byte read/write":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

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

      let transport1: TcpTransport = TcpTransport.init()
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
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
      await allFuturesThrowing(
        transport1.close(),
        transport2.close())
      await listenFut

    waitFor(test())

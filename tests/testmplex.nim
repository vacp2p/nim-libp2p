import unittest, strformat, strformat, random
import chronos, nimcrypto/utils, chronicles
import ../libp2p/[errors,
                  connection,
                  stream/lpstream,
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
      check tracker.isLeaked() == false

  test "encode header with channel id 0":
    proc testEncodeHeader(): Future[bool] {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("000873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = newConnection(stream)
      await conn.writeMsg(0, MessageType.New, cast[seq[byte]]("stream 1"))

      result = true

      await stream.close()

    check:
      waitFor(testEncodeHeader()) == true

  test "encode header with channel id other than 0":
    proc testEncodeHeader(): Future[bool] {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("88010873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = newConnection(stream)
      await conn.writeMsg(17, MessageType.New, cast[seq[byte]]("stream 1"))

      result = true

      await stream.close()

    check:
      waitFor(testEncodeHeader()) == true

  test "encode header and body with channel id 0":
    proc testEncodeHeaderBody(): Future[bool] {.async.} =
      var step = 0
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("020873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = newConnection(stream)
      await conn.writeMsg(0, MessageType.MsgOut, cast[seq[byte]]("stream 1"))

      result = true

      await stream.close()

    check:
      waitFor(testEncodeHeaderBody()) == true

  test "encode header and body with channel id other than 0":
    proc testEncodeHeaderBody(): Future[bool] {.async.} =
      var step = 0
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("8a010873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = newConnection(stream)
      await conn.writeMsg(17, MessageType.MsgOut, cast[seq[byte]]("stream 1"))
      await conn.close()

      result = true

      await stream.close()

    check:
      waitFor(testEncodeHeaderBody()) == true

  test "decode header with channel id 0":
    proc testDecodeHeader(): Future[bool] {.async.} =
      let stream = newBufferStream()
      let conn = newConnection(stream)
      await stream.pushTo(fromHex("000873747265616d2031"))
      let msg = await conn.readMsg()

      check msg.id == 0
      check msg.msgType == MessageType.New

      result = true

      await stream.close()

    check:
      waitFor(testDecodeHeader()) == true

  test "decode header and body with channel id 0":
    proc testDecodeHeader(): Future[bool] {.async.} =
      let stream = newBufferStream()
      let conn = newConnection(stream)
      await stream.pushTo(fromHex("021668656C6C6F2066726F6D206368616E6E656C20302121"))
      let msg = await conn.readMsg()

      check msg.id == 0
      check msg.msgType == MessageType.MsgOut
      check cast[string](msg.data) == "hello from channel 0!!"

      result = true

      await stream.close()

    check:
      waitFor(testDecodeHeader()) == true

  test "decode header and body with channel id other than 0":
    proc testDecodeHeader(): Future[bool] {.async.} =
      let stream = newBufferStream()
      let conn = newConnection(stream)
      await stream.pushTo(fromHex("8a011668656C6C6F2066726F6D206368616E6E656C20302121"))
      let msg = await conn.readMsg()

      check msg.id == 17
      check msg.msgType == MessageType.MsgOut
      check cast[string](msg.data) == "hello from channel 0!!"

      result = true

      await stream.close()

    check:
      waitFor(testDecodeHeader()) == true

  test "e2e - read/write receiver":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var
        done = newFuture[void]()
        done2 = newFuture[void]()

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == "Hello from stream!"
          await stream.close()
          done.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()
        await conn.close()
        done2.complete()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let lfut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream()
      let openState = cast[LPChannel](stream.stream).isOpen
      await stream.writeLp("Hello from stream!")
      await conn.close()
      check openState # not lazy

      result = true

      await done.wait(5000.millis)
      await done2.wait(5000.millis)
      await stream.close()
      await conn.close()
      await transport2.close()
      await transport1.close()
      await lfut

    check:
      waitFor(testNewStream()) == true

  test "e2e - read/write receiver lazy":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var
        done = newFuture[void]()
        done2 = newFuture[void]()

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == "Hello from stream!"
          await stream.close()
          done.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()
        done2.complete()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream("", true)
      let openState = cast[LPChannel](stream.stream).isOpen
      await stream.writeLp("Hello from stream!")
      await conn.close()

      check not openState # assert lazy
      result = true

      await done.wait(5000.millis)
      await done2.wait(5000.millis)
      await conn.close()
      await stream.close()
      await mplexDial.close()
      await transport2.close()
      await transport1.close()
      await listenFut

    check:
      waitFor(testNewStream()) == true

  test "e2e - write fragmented":
    proc testNewStream(): Future[bool] {.async.} =
      let
        ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
        listenJob = newFuture[void]()

      var bigseq = newSeqOfCap[uint8](MaxMsgSize * 2)
      for _ in 0..<MaxMsgSize:
        bigseq.add(uint8(rand(uint('A')..uint('z'))))

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          defer:
            await stream.close()
          let msg = await stream.readLp(MaxMsgSize)
          check msg == bigseq
          trace "Bigseq check passed!"
          listenJob.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream  = await mplexDial.newStream()

      await stream.writeLp(bigseq)
      try:
        await listenJob.wait(millis(5000))
      except AsyncTimeoutError:
        check false

      result = true

      await stream.close()
      await mplexDial.close()
      await conn.close()
      await transport2.close()
      await transport1.close()
      await listenFut

    check:
      waitFor(testNewStream()) == true

  test "e2e - read/write initiator":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let done = newFuture[void]()

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          await stream.writeLp("Hello from stream!")
          await stream.close()
          done.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let dialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream("DIALER")
      let msg = cast[string](await stream.readLp(1024))
      check msg == "Hello from stream!"

      # await dialFut
      result = true

      await done.wait(5000.millis)
      await stream.close()
      await conn.close()
      await mplexDial.close()
      await transport2.close()
      await transport1.close()
      await listenFut

    check:
      waitFor(testNewStream()) == true

  test "e2e - multiple streams":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let done = newFuture[void]()

      var count = 1
      var listenConn: Connection
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == &"stream {count}!"
          count.inc
          await stream.close()
          if count == 10:
            done.complete()

        listenConn = conn
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1 = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      for i in 1..10:
        let stream  = await mplexDial.newStream()
        await stream.writeLp(&"stream {i}!")
        await stream.close()

      await done.wait(5000.millis)
      await conn.close()
      await transport2.close()
      await mplexDial.close()
      await listenConn.close()
      await transport1.close()
      await listenFut

      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - multiple read/write streams":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var count = 1
      var listenConn: Connection
      let done = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        listenConn = conn
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp(1024)
          check cast[string](msg) == &"stream {count} from dialer!"
          await stream.writeLp(&"stream {count} from listener!")
          count.inc
          await stream.close()
          if count == 10:
            done.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let transportFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let dialFut = mplexDial.handle()
      dialFut.addCallback(proc(udata: pointer = nil) {.gcsafe.}
                            = trace "completed dialer")
      for i in 1..10:
        let stream  = await mplexDial.newStream("dialer stream")
        await stream.writeLp(&"stream {i} from dialer!")
        let msg = await stream.readLp(1024)
        check cast[string](msg) == &"stream {i} from listener!"
        await stream.close()

      await done.wait(5.seconds)
      await conn.close()
      await listenConn.close()
      await allFuturesThrowing(dialFut)
      await mplexDial.close()
      await transport2.close()
      await transport1.close()
      await transportFut
      result = true

    check:
      waitFor(testNewStream()) == true

  test "half closed - channel should close for write":
    proc testClosedForWrite(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        buff = newBufferStream(writeHandler)
        conn = newConnection(buff)
        chann = newChannel(1, conn, true)
      try:
        await chann.close()
        await chann.write("Hello")
      finally:
        await chann.cleanUp()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testClosedForWrite())

  test "half closed - channel should close for read by remote":
    proc testClosedForRead(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} =
        discard

      let
        buff = newBufferStream(writeHandler)
        conn = newConnection(buff)
        chann = newChannel(1, conn, true)

      try:
        await chann.pushTo(cast[seq[byte]]("Hello!"))
        await chann.closedByRemote()
        var data = newSeq[byte](6)
        await chann.readExactly(addr data[0], 6) # this should work, since there is data in the buffer
        await chann.readExactly(addr data[0], 6) # this should throw
      finally:
        await chann.cleanUp()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testClosedForRead())

  test "jitter - channel should be able to handle erratic read/writes":
    proc test(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var complete = newFuture[void]()
      const MsgSize = 1024
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp(MsgSize)
          check msg.len == MsgSize
          await stream.close()
          complete.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
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
      await complete

      await transport2.close()
      await transport1.close()
      await listenFut

      result = true

    check:
      waitFor(test()) == true

  test "jitter - channel should handle 1 byte read/write":
    proc test(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var complete = newFuture[void]()
      const MsgSize = 512
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp(MsgSize)
          check msg.len == MsgSize
          await stream.close()
          complete.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let listenFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
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
        for i in buf.buffer:
          await conn.write(@[i])

      await writer()

      await stream.close()
      await conn.close()
      await complete
      await transport2.close()
      await transport1.close()
      await listenFut

      result = true

    check:
      waitFor(test()) == true

  test "reset - channel should fail reading":
    proc testResetRead(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        buff = newBufferStream(writeHandler)
        conn = newConnection(buff)
        chann = newChannel(1, conn, true)

      try:
        await chann.reset()
        var data = newSeq[byte](1)
        await chann.readExactly(addr data[0], 1)
        doAssert(len(data) == 1)
      finally:
        await chann.cleanUp()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testResetRead())

  test "reset - channel should fail writing":
    proc testResetWrite(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        buff = newBufferStream(writeHandler)
        conn = newConnection(buff)
        chann = newChannel(1, conn, true)
      try:
        await chann.reset()
        await chann.write(cast[seq[byte]]("Hello!"))
      finally:
        await chann.cleanUp()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testResetWrite())

  test "should not allow pushing data to channel when remote end closed":
    proc testResetWrite(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let
        buff = newBufferStream(writeHandler)
        conn = newConnection(buff)
        chann = newChannel(1, conn, true)
      try:
        await chann.closedByRemote()
        await chann.pushTo(@[byte(1)])
      finally:
        await chann.cleanUp()
        await conn.close()

    expect LPStreamEOFError:
      waitFor(testResetWrite())

import unittest, sequtils, sugar, strformat, options, strformat, random
import chronos, nimcrypto/utils, chronicles
import ../libp2p/[connection,
                  stream/lpstream,
                  stream/bufferstream,
                  transports/tcptransport,
                  transports/transport,
                  protocols/identify,
                  multiaddress,
                  muxers/mplex/mplex,
                  muxers/mplex/coder,
                  muxers/mplex/types,
                  muxers/mplex/lpchannel,
                  vbuffer,
                  varint]

when defined(nimHasUsed): {.used.}

suite "Mplex":
  test "encode header with channel id 0":
    proc testEncodeHeader(): Future[bool] {.async.} =
      proc encHandler(msg: seq[byte]) {.async.} =
        check msg == fromHex("000873747265616d2031")

      let stream = newBufferStream(encHandler)
      let conn = newConnection(stream)
      await conn.writeMsg(0, MessageType.New, cast[seq[byte]]("stream 1"))
      result = true

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

    check:
      waitFor(testDecodeHeader()) == true

  test "e2e - read/write receiver":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp()
          check cast[string](msg) == "Hello from stream!"
          await stream.close()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)

      defer:
        await transport1.close()

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream()
      let openState = cast[LPChannel](stream.stream).isOpen
      await stream.writeLp("Hello from stream!")
      await conn.close()
      check openState # not lazy
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - read/write receiver lazy":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp()
          check cast[string](msg) == "Hello from stream!"
          await stream.close()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)
      defer:
        await transport1.close()

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let stream = await mplexDial.newStream("", true)
      let openState = cast[LPChannel](stream.stream).isOpen
      await stream.writeLp("Hello from stream!")
      await conn.close()
      check not openState # assert lazy
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - write limits":
    proc testNewStream(): Future[bool] {.async.} =
      let
        ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
        listenJob = newFuture[void]()

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          defer:
            await stream.close()
          let msg = await stream.readLp()
          # we should not reach this anyway!!
          check false
          listenJob.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)
      defer:
        await transport1.close()

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)
      defer:
        await conn.close()

      let mplexDial = newMplex(conn)
      let stream  = await mplexDial.newStream()
      var bigseq = newSeqOfCap[uint8](MaxMsgSize + 1)
      for _ in 0..<MaxMsgSize:
        bigseq.add(uint8(rand(uint('A')..uint('z'))))
      await stream.writeLp(bigseq)
      try:
        await listenJob.wait(millis(500))
      except AsyncTimeoutError:
        # we want to time out here!
        discard
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - read/write initiator":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          await stream.writeLp("Hello from stream!")
          await stream.close()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)
      defer:
        await transport1.close()

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let dialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream("DIALER")
      let msg = cast[string](await stream.readLp())
      check msg == "Hello from stream!"
      await conn.close()
      # await dialFut
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - multiple streams":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var count = 1
      var listenConn: Connection
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp()
          check cast[string](msg) == &"stream {count}!"
          count.inc
          await stream.close()

        listenConn = conn
        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)
      defer:
        await transport1.close()

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      for i in 1..<10:
        let stream  = await mplexDial.newStream()
        await stream.writeLp(&"stream {i}!")
        await stream.close()

      await conn.close()
      await listenConn.close()
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - multiple read/write streams":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var count = 1
      var listenFut: Future[void]
      var listenConn: Connection
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        listenConn = conn
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp()
          check cast[string](msg) == &"stream {count} from dialer!"
          await stream.writeLp(&"stream {count} from listener!")
          count.inc
          await stream.close()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        listenFut = mplexListen.handle()
        listenFut.addCallback(proc(udata: pointer) {.gcsafe.}
                                = trace "completed listener")

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard transport1.listen(ma, connHandler)
      defer:
        await transport1.close()

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let mplexDial = newMplex(conn)
      let dialFut = mplexDial.handle()
      dialFut.addCallback(proc(udata: pointer = nil) {.gcsafe.}
                            = trace "completed dialer")
      for i in 1..10:
        let stream  = await mplexDial.newStream("dialer stream")
        await stream.writeLp(&"stream {i} from dialer!")
        let msg = await stream.readLp()
        check cast[string](msg) == &"stream {i} from listener!"
        await stream.close()

      await conn.close()
      await listenConn.close()
      await allFutures(dialFut, listenFut)
      result = true

    check:
      waitFor(testNewStream()) == true

  test "half closed - channel should close for write":
    proc testClosedForWrite(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let chann = newChannel(1, newConnection(newBufferStream(writeHandler)), true)
      await chann.close()
      await chann.write("Hello")

    expect LPStreamEOFError:
      waitFor(testClosedForWrite())

  # TODO: this locks up after removing sleepAsync as a
  # synchronization mechanism in mplex. I believe this
  # is related to how chronos schedules callbacks in select,
  # which effectively puts to infinite sleep when there
  # are no more callbacks, so essentially this sequence of
  # reads isn't possible with the current chronos.
  # test "half closed - channel should close for read by remote":
  #   proc testClosedForRead(): Future[void] {.async.} =
  #     proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
  #     let chann = newChannel(1, newConnection(newBufferStream(writeHandler)), true)

  #     await chann.pushTo(cast[seq[byte]]("Hello!"))
  #     await chann.closedByRemote()
  #     discard await chann.read() # this should work, since there is data in the buffer
  #     discard await chann.read() # this should throw

  #   expect LPStreamEOFError:
  #     waitFor(testClosedForRead())

  test "jitter - channel should be able to handle erratic read/writes":
    proc test(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var complete = newFuture[void]()
      const MsgSize = 1024
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp()
          check msg.len == MsgSize
          await stream.close()
          complete.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)

      defer:
        await transport1.close()

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
          let msg = await stream.readLp()
          check msg.len == MsgSize
          await stream.close()
          complete.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        discard mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      discard await transport1.listen(ma, connHandler)

      defer:
        await transport1.close()

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

      result = true

    check:
      waitFor(test()) == true

  test "reset - channel should fail reading":
    proc testResetRead(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let chann = newChannel(1, newConnection(newBufferStream(writeHandler)), true)
      await chann.reset()
      var data = await chann.read()
      doAssert(len(data) == 1)

    expect LPStreamEOFError:
      waitFor(testResetRead())

  test "reset - channel should fail writing":
    proc testResetWrite(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let chann = newChannel(1, newConnection(newBufferStream(writeHandler)), true)
      await chann.reset()
      await chann.write(cast[seq[byte]]("Hello!"))

    expect LPStreamEOFError:
      waitFor(testResetWrite())

  test "should not allow pushing data to channel when remote end closed":
    proc testResetWrite(): Future[void] {.async.} =
      proc writeHandler(data: seq[byte]) {.async, gcsafe.} = discard
      let chann = newChannel(1, newConnection(newBufferStream(writeHandler)), true)
      await chann.closedByRemote()
      await chann.pushTo(@[byte(1)])

    expect LPStreamEOFError:
      waitFor(testResetWrite())

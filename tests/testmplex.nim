import unittest, sequtils, sugar, strformat
import chronos, nimcrypto/utils
import ../libp2p/connection, 
       ../libp2p/stream/lpstream, 
       ../libp2p/stream/bufferstream, 
       ../libp2p/transports/tcptransport, 
       ../libp2p/transports/transport, 
       ../libp2p/protocols/identify, 
       ../libp2p/multiaddress,
       ../libp2p/muxers/mplex/mplex, 
       ../libp2p/muxers/mplex/coder, 
       ../libp2p/muxers/mplex/types,
       ../libp2p/muxers/mplex/channel

type
  TestEncodeStream = ref object of LPStream
    handler*: proc(data: seq[byte])

method write*(s: TestEncodeStream, 
              msg: seq[byte], 
              msglen = -1): 
              Future[void] {.gcsafe.} =
  s.handler(msg)

proc newTestEncodeStream(handler: proc(data: seq[byte])): TestEncodeStream =
  new result
  result.handler = handler

type
  TestDecodeStream = ref object of LPStream
      handler*: proc(data: seq[byte])
      step*: int
      msg*: seq[byte]

method readExactly*(s: TestDecodeStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] {.async, gcsafe.} =
  let buff: seq[byte] = s.msg
  copyMem(pbytes, unsafeAddr buff[s.step], nbytes)
  s.step += nbytes

proc newTestDecodeStream(): TestDecodeStream =
  new result
  result.step = 0
  result.msg = fromHex("8801023137")

suite "Mplex":
  test "encode header":
    proc testEncodeHeader(): Future[bool] {.async.} =
      proc encHandler(msg: seq[byte]) =
        check msg == fromHex("886f04")
      
      let conn = newConnection(newTestEncodeStream(encHandler))
      await conn.writeHeader(1777, MessageType.New, 4)
      result = true

    check:
      waitFor(testEncodeHeader()) == true

  test "decode header":
    proc testDecodeHeader(): Future[bool] {.async.} =
      let conn = newConnection(newTestDecodeStream())
      let (id, msgType) = await conn.readHeader()

      check id == 17
      check msgType == MessageType.New
      let data = await conn.readLp()
      check cast[string](data) == "17"
      result = true

    check:
      waitFor(testDecodeHeader()) == true
    
  test "e2e - read/write initiator":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53380")

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} = 
          await stream.writeLp("Hello from stream!")
          await stream.close()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let mplexDial = newMplex(conn)
      let dialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream()
      check cast[string](await stream.readLp()) == "Hello from stream!"
      await conn.close()
      await dialFut
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - read/write receiver":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53381")

      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} = 
          let msg = await stream.readLp()
          check cast[string](msg) == "Hello from stream!"
          await stream.close()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        await mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let mplexDial = newMplex(conn)
      let dialFut = mplexDial.handle()
      let stream  = await mplexDial.newStream()
      await stream.writeLp("Hello from stream!")
      await conn.close()
      await dialFut
      result = true

    check:
      waitFor(testNewStream()) == true

  test "e2e - multiple streams":
    proc testNewStream(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53382")

      var count = 0
      var completionFut: Future[void] = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        proc handleMplexListen(stream: Connection) {.async, gcsafe.} = 
          let msg = await stream.readLp()
          check cast[string](msg) == &"Hello from stream {count}!"
          count.inc
          await stream.close()
          if count == 11:
            completionFut.complete()

        let mplexListen = newMplex(conn)
        mplexListen.streamHandler = handleMplexListen
        asyncCheck mplexListen.handle()

      let transport1: TcpTransport = newTransport(TcpTransport)
      await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let mplexDial = newMplex(conn)
      asyncCheck mplexDial.handle()

      for i in 0..10:
        let stream  = await mplexDial.newStream()
        await stream.writeLp(&"Hello from stream {i}!")

      await completionFut
      # closing the connection doesn't transfer all the data
      # this seems to be a bug in chronos
      # await conn.close()
      check count == 11

      result = true

    check:
      waitFor(testNewStream()) == true

  test "half closed - channel should close for write":
    proc testClosedForWrite(): Future[void] {.async.} =
      let chann = newChannel(1, newConnection(new LPStream), true)
      await chann.close()
      await chann.write("Hello")

    expect LPStreamClosedError:
      waitFor(testClosedForWrite())

  test "half closed - channel should close for read":
    proc testClosedForRead(): Future[void] {.async.} =
      let chann = newChannel(1, newConnection(new LPStream), true)
      await chann.closedByRemote()
      asyncDiscard chann.read()

    expect LPStreamClosedError:
      waitFor(testClosedForRead())

  test "half closed - channel should close for read after eof":
    proc testClosedForRead(): Future[void] {.async.} =
      let chann = newChannel(1, newConnection(new LPStream), true)

      await chann.pushTo(cast[seq[byte]](toSeq("Hello!".items)))
      await chann.close()
      let msg = await chann.read()
      asyncDiscard chann.read()

    expect LPStreamClosedError:
      waitFor(testClosedForRead())

  test "reset - channel should fail reading":
    proc testResetRead(): Future[void] {.async.} =
      let chann = newChannel(1, newConnection(new LPStream), true)
      await chann.reset()
      asyncDiscard chann.read()

    expect LPStreamClosedError:
      waitFor(testResetRead())

  test "reset - channel should fail writing":
    proc testResetWrite(): Future[void] {.async.} =
      let chann = newChannel(1, newConnection(new LPStream), true)
      await chann.reset()
      asyncDiscard chann.read()

    expect LPStreamClosedError:
      waitFor(testResetWrite())

  test "should not allow pushing data to channel when remote end closed":
    proc testResetWrite(): Future[void] {.async.} =
      let chann = newChannel(1, newConnection(new LPStream), true)
      await chann.closedByRemote()
      await chann.pushTo(@[byte(1)])

    expect LPStreamClosedError:
      waitFor(testResetWrite())

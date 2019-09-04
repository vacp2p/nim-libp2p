import unittest, sequtils, sugar
import chronos, nimcrypto/utils
import ../libp2p/muxers/mplex, ../libp2p/connection,
       ../libp2p/stream/lpstream, ../libp2p/tcptransport,
       ../libp2p/transport, ../libp2p/multiaddress

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
        check msg == fromHex("880102")
      
      let conn = newConnection(newTestEncodeStream(encHandler))
      await conn.writeHeader(17, MessageType.New, 2)
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

          let mplexListen = newMplex(conn, handleMplexListen)
          await mplexListen.handle()

        let transport1: TcpTransport = newTransport(TcpTransport)
        await transport1.listen(ma, connHandler)

        let transport2: TcpTransport = newTransport(TcpTransport)
        let conn = await transport2.dial(ma)

        proc handleDial(stream: Connection) {.async, gcsafe.} = discard
        let mplexDial = newMplex(conn, handleDial)
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

          let mplexListen = newMplex(conn, handleMplexListen)
          await mplexListen.handle()

        let transport1: TcpTransport = newTransport(TcpTransport)
        await transport1.listen(ma, connHandler)

        let transport2: TcpTransport = newTransport(TcpTransport)
        let conn = await transport2.dial(ma)

        proc handleDial(stream: Connection) {.async, gcsafe.} = discard
        let mplexDial = newMplex(conn, handleDial)
        let dialFut = mplexDial.handle()
        let stream  = await mplexDial.newStream()
        await stream.writeLp("Hello from stream!")
        await dialFut
        result = true

      check:
        waitFor(testNewStream()) == true

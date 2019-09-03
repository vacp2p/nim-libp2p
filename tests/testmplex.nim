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
  # test "encode header":
  #   proc testEncodeHeader(): Future[bool] {.async.} =
  #     proc encHandler(msg: seq[byte]) =
  #       check msg == fromHex("880102")
      
  #     let conn = newConnection(newTestEncodeStream(encHandler))
  #     await conn.writeHeader(uint(17), MessageType.New, 2)
  #     result = true

  #   check:
  #     waitFor(testEncodeHeader()) == true

  # test "decode header":
  #   proc testDecodeHeader(): Future[bool] {.async.} =
  #     let conn = newConnection(newTestDecodeStream())
  #     let (id, msgType) = await conn.readHeader()

  #     check id == 17
  #     check msgType == MessageType.New
  #     let data = await conn.readLp()
  #     check cast[string](data) == "17"
  #     result = true

  #   check:
  #     waitFor(testDecodeHeader()) == true
    
    test "e2e - new stream":
      proc testNewStream(): Future[bool] {.async.} =
        let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53351")

        proc connHandler(conn: Connection) {.async, gcsafe.} =
          proc handleListen(stream: Connection) {.async, gcsafe.} =
            await stream.writeLp("Hello from stream!")

          let mplexListen = newMplex(conn, handleListen)
          await mplexListen.handle()

        let transport1: TcpTransport = newTransport(TcpTransport)
        await transport1.listen(ma, connHandler)

        let transport2: TcpTransport = newTransport(TcpTransport)
        let conn = await transport2.dial(ma)
        proc handleDial(stream: Connection) {.async, gcsafe.} =
          let msg = await stream.readLp()

        let mplexDial = newMplex(conn, handleDial)
        let handleFut = mplexDial.handle()
        result = true

      check:
        waitFor(testNewStream()) == true

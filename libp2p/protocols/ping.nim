## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options, random
import chronos, chronicles
import ../protobuf/minprotobuf,
       ../peerinfo,
       ../stream/connection,
       ../peerid,
       ../crypto/crypto,
       ../multiaddress,
       ../protocols/protocol,
       ../errors

logScope:
  topics = "libp2p ping"

const
  PingCodec* = "/ipfs/ping/1.0.0"
  PingSize = 32

type
  PingError* = object of LPError
  WrongPingAckError* = object of LPError

  PingHandler* = proc (
    peer: PeerInfo):
    Future[void]
    {.gcsafe, raises: [Defect].}

  Ping* = ref object of LPProtocol
    pingHandler*: PingHandler

proc newPing*(handler: PingHandler = nil): Ping =
  new result
  result.pingHandler = handler
  result.init()

method init*(p: Ping) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    try:
      trace "handling ping", conn
      var buf: array[PingSize, byte]
      await conn.readExactly(addr buf[0], PingSize)
      await conn.write(addr buf[0], PingSize)
      if not isNil(p.pingHandler):
        await p.pingHandler(conn.peerInfo)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in ping handler", exc = exc.msg, conn

  p.handler = handle
  p.codec = PingCodec

proc ping*(
  p: Ping,
  conn: Connection,
  ): Future[Duration] {.async, gcsafe.} =
  ## Sends ping to `conn`
  ## Returns the delay
  ##

  trace "initiating ping", conn

  var
    randomBuf: array[PingSize, byte]
    resultBuf: array[PingSize, byte]

  for i in 0..<PingSize:
    randomBuf[i] = byte.rand()

  let startTime = Moment.now()

  trace "sending ping", conn
  await conn.write(addr randomBuf[0], randomBuf.len)

  await conn.readExactly(addr resultBuf[0], PingSize)

  let responseTime = Moment.now() - startTime

  trace "got ping response", conn, responseTime

  for i in 0..<randomBuf.len:
    if randomBuf[i] != resultBuf[i]:
      raise newException(WrongPingAckError, "Incorrect ping data from peer!")

  trace "valid ping response", conn
  return responseTime

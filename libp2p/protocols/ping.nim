# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## `Ping <https://docs.libp2p.io/concepts/protocols/#ping>`_ protocol implementation

{.push raises: [].}

import chronos, chronicles
import bearssl/rand
import
  ../protobuf/minprotobuf,
  ../peerinfo,
  ../stream/connection,
  ../peerid,
  ../crypto/crypto,
  ../multiaddress,
  ../protocols/protocol,
  ../utility,
  ../errors

export chronicles, rand, connection

logScope:
  topics = "libp2p ping"

const
  PingCodec* = "/ipfs/ping/1.0.0"
  PingSize = 32

type
  PingError* = object of LPError
  WrongPingAckError* = object of PingError

  PingHandler* {.public.} = proc(peer: PeerId): Future[void] {.gcsafe, raises: [].}

  Ping* = ref object of LPProtocol
    pingHandler*: PingHandler
    rng: ref HmacDrbgContext

proc new*(
    T: typedesc[Ping], handler: PingHandler = nil, rng: ref HmacDrbgContext = newRng()
): T {.public.} =
  let ping = Ping(pinghandler: handler, rng: rng)
  ping.init()
  ping

method init*(p: Ping) =
  proc handle(conn: Connection, proto: string) {.async.} =
    echo "######### Before Ping #########"
    try:
      trace "handling ping", conn
      var buf: array[PingSize, byte]
      await conn.readExactly(addr buf[0], PingSize)
      trace "echoing ping", conn, pingData = @buf
      await conn.write(@buf)
      if not isNil(p.pingHandler):
        await p.pingHandler(conn.peerId)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in ping handler", description = exc.msg, conn
    echo "######### After Ping #########"

  p.handler = handle
  p.codec = PingCodec

proc ping*(p: Ping, conn: Connection): Future[Duration] {.async, public.} =
  ## Sends ping to `conn`, returns the delay
  echo "######### Pinging #########"
  echo conn.shortLog()
  trace "initiating ping", conn

  var
    randomBuf: array[PingSize, byte]
    resultBuf: array[PingSize, byte]

  hmacDrbgGenerate(p.rng[], randomBuf)

  let startTime = Moment.now()

  trace "sending ping", conn
  echo "# Before Write. Is conn closed? ", conn.isClosed, conn.isEof
  await conn.write(@randomBuf)
  echo "# After Write. Is conn closed? ", conn.isClosed, conn.isEof

  await conn.readExactly(addr resultBuf[0], PingSize)
  echo "# After Read. Is conn closed? ", conn.isClosed

  let responseDur = Moment.now() - startTime

  trace "got ping response", conn, responseDur

  for i in 0 ..< randomBuf.len:
    if randomBuf[i] != resultBuf[i]:
      raise newException(WrongPingAckError, "Incorrect ping data from peer!")

  trace "valid ping response", conn
  echo "######### Pinged #########"
  return responseDur

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## `Ping <https://docs.libp2p.io/concepts/protocols/#ping>`_ protocol implementation

{.push raises: [].}

import chronos, chronicles
import
  ../peerinfo,
  ../stream/connection,
  ../peerid,
  ../crypto/crypto,
  ../multiaddress,
  ../protocols/protocol,
  ../errors

export chronicles, rng, connection

logScope:
  topics = "libp2p ping"

const
  PingCodec* = "/ipfs/ping/1.0.0"
  PingSize = 32

type
  PingError* = object of LPError
  WrongPingAckError* = object of PingError

  PingHandler* = proc(peer: PeerId): Future[void] {.gcsafe, raises: [].}

  Ping* = ref object of LPProtocol
    pingHandler*: PingHandler
    rng: Rng

proc new*(T: typedesc[Ping], handler: PingHandler = nil, rng: Rng): T =
  let ping = Ping(pinghandler: handler, rng: rng)
  ping.init()
  ping

method init*(p: Ping) =
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      trace "handling ping", stream
      var buf: array[PingSize, byte]
      await stream.readExactly(addr buf[0], PingSize)
      trace "echoing ping", stream, pingData = @buf
      await stream.write(@buf)
      if not isNil(p.pingHandler):
        await p.pingHandler(stream.peerId)
    except CancelledError as exc:
      trace "cancelled ping handler"
      raise exc
    except CatchableError as exc:
      trace "exception in ping handler", description = exc.msg, stream

  p.handler = handle
  p.codec = PingCodec

proc ping*(
    p: Ping, stream: Stream
): Future[Duration] {.
    async: (raises: [CancelledError, LPStreamError, WrongPingAckError])
.} =
  ## Sends ping to `stream`, returns the delay

  trace "initiating ping", stream

  var
    randomBuf: array[PingSize, byte]
    resultBuf: array[PingSize, byte]

  p.rng.generate(randomBuf)

  let startTime = Moment.now()

  trace "sending ping", stream
  await stream.write(@randomBuf)

  await stream.readExactly(addr resultBuf[0], PingSize)

  let responseDur = Moment.now() - startTime

  trace "got ping response", stream, responseDur

  for i in 0 ..< randomBuf.len:
    if randomBuf[i] != resultBuf[i]:
      raise newException(WrongPingAckError, "Incorrect ping data from peer!")

  trace "valid ping response", stream
  return responseDur

# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, chronicles
import ./messages, ../../../stream/connection

logScope:
  topics = "libp2p relay relay-utils"

const
  RelayV1Codec* = "/libp2p/circuit/relay/0.1.0"
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"

proc sendStatus*(
    conn: Connection, code: StatusV1
) {.async: (raises: [CancelledError]).} =
  trace "send relay/v1 status", status = $code & "(" & $ord(code) & ")"
  try:
    let
      msg = RelayMessage(msgType: Opt.some(RelayType.Status), status: Opt.some(code))
      pb = encode(msg)
    await conn.writeLp(pb.buffer)
  except CancelledError as e:
    raise e
  except LPStreamError as e:
    trace "error sending relay status", description = e.msg

proc sendHopStatus*(
    conn: Connection, code: StatusV2
) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  trace "send hop relay/v2 status", status = $code & "(" & $ord(code) & ")"
  let
    msg = HopMessage(msgType: HopMessageType.Status, status: Opt.some(code))
    pb = encode(msg)
  conn.writeLp(pb.buffer)

proc sendStopStatus*(
    conn: Connection, code: StatusV2
) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  trace "send stop relay/v2 status", status = $code & " (" & $ord(code) & ")"
  let
    msg = StopMessage(msgType: StopMessageType.Status, status: Opt.some(code))
    pb = encode(msg)
  conn.writeLp(pb.buffer)

proc bridge*(
    connSrc: Connection, connDst: Connection
) {.async: (raises: [CancelledError]).} =
  const bufferSize = 4096
  var
    bufSrcToDst: array[bufferSize, byte]
    bufDstToSrc: array[bufferSize, byte]
    futSrc = connSrc.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
    futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
    bytesSentFromSrcToDst = 0
    bytesSentFromDstToSrc = 0
    bufRead: int

  try:
    while not connSrc.closed() and not connDst.closed():
      try: # https://github.com/status-im/nim-chronos/issues/516
        discard await race(futSrc, futDst)
      except ValueError:
        raiseAssert("Futures list is not empty: " & getCurrentExceptionMsg())
      if futSrc.finished():
        bufRead = await futSrc
        if bufRead > 0:
          bytesSentFromSrcToDst.inc(bufRead)
          await connDst.write(@bufSrcToDst[0 ..< bufRead])
          zeroMem(addr bufSrcToDst[0], bufSrcToDst.len)
        futSrc = connSrc.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
      if futDst.finished():
        bufRead = await futDst
        if bufRead > 0:
          bytesSentFromDstToSrc += bufRead
          await connSrc.write(bufDstToSrc[0 ..< bufRead])
          zeroMem(addr bufDstToSrc[0], bufDstToSrc.len)
        futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    if connSrc.closed() or connSrc.atEof():
      trace "relay src closed connection", src = connSrc.peerId
    if connDst.closed() or connDst.atEof():
      trace "relay dst closed connection", dst = connDst.peerId
    trace "relay error", description = exc.msg
  trace "end relaying", bytesSentFromSrcToDst, bytesSentFromDstToSrc
  await futSrc.cancelAndWait()
  await futDst.cancelAndWait()

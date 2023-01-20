# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import options

import chronos, chronicles

import ./messages,
       ../../../stream/connection

logScope:
  topics = "libp2p relay relay-utils"

const
  RelayV1Codec* = "/libp2p/circuit/relay/0.1.0"
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"

proc sendStatus*(conn: Connection, code: StatusV1) {.async, gcsafe.} =
  trace "send relay/v1 status", status = $code & "(" & $ord(code) & ")"
  let
    msg = RelayMessage(msgType: some(RelayType.Status), status: some(code))
    pb = encode(msg)
  await conn.writeLp(pb.buffer)

proc sendHopStatus*(conn: Connection, code: StatusV2) {.async, gcsafe.} =
  trace "send hop relay/v2 status", status = $code & "(" & $ord(code) & ")"
  let
    msg = HopMessage(msgType: HopMessageType.Status, status: some(code))
    pb = encode(msg)
  await conn.writeLp(pb.buffer)

proc sendStopStatus*(conn: Connection, code: StatusV2) {.async.} =
  trace "send stop relay/v2 status", status = $code & " (" & $ord(code) & ")"
  let
    msg = StopMessage(msgType: StopMessageType.Status, status: some(code))
    pb = encode(msg)
  await conn.writeLp(pb.buffer)

proc bridge*(connSrc: Connection, connDst: Connection) {.async.} =
  const bufferSize = 4096
  var
    bufSrcToDst: array[bufferSize, byte]
    bufDstToSrc: array[bufferSize, byte]
    futSrc = connSrc.readOnce(addr bufSrcToDst[0], bufSrcToDst.high + 1)
    futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.high + 1)
    bytesSendFromSrcToDst = 0
    bytesSendFromDstToSrc = 0
    bufRead: int

  try:
    while not connSrc.closed() and not connDst.closed():
      await futSrc or futDst
      if futSrc.finished():
        bufRead = await futSrc
        if bufRead > 0:
          bytesSendFromSrcToDst.inc(bufRead)
          await connDst.write(@bufSrcToDst[0..<bufRead])
          zeroMem(addr(bufSrcToDst), bufSrcToDst.high + 1)
        futSrc = connSrc.readOnce(addr bufSrcToDst[0], bufSrcToDst.high + 1)
      if futDst.finished():
        bufRead = await futDst
        if bufRead > 0:
          bytesSendFromDstToSrc += bufRead
          await connSrc.write(bufDstToSrc[0..<bufRead])
          zeroMem(addr(bufDstToSrc), bufDstToSrc.high + 1)
        futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.high + 1)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    if connSrc.closed() or connSrc.atEof():
      trace "relay src closed connection", src = connSrc.peerId
    if connDst.closed() or connDst.atEof():
      trace "relay dst closed connection", dst = connDst.peerId
    trace "relay error", exc=exc.msg
  trace "end relaying", bytesSendFromSrcToDst, bytesSendFromDstToSrc
  await futSrc.cancelAndWait()
  await futDst.cancelAndWait()

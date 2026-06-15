# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, chronicles
import ./messages, ../../../stream/connection

logScope:
  topics = "libp2p relay relay-utils"

const
  RelayV1Codec* = "/libp2p/circuit/relay/0.1.0"
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"

proc sendStatus*(stream: Stream, code: StatusV1) {.async: (raises: [CancelledError]).} =
  trace "send relay/v1 status", status = $code & "(" & $ord(code) & ")"
  try:
    let msg = RelayMessage(msgType: Opt.some(RelayType.Status), status: Opt.some(code))
    await stream.writeLp(encode(msg))
  except CancelledError as e:
    raise e
  except LPStreamError as e:
    trace "error sending relay status", description = e.msg

proc sendHopStatus*(
    stream: Stream, code: StatusV2
) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  trace "send hop relay/v2 status", status = $code & "(" & $ord(code) & ")"
  let msg = HopMessage(msgType: Opt.some(HopMessageType.Status), status: Opt.some(code))
  stream.writeLp(encode(msg))

proc sendStopStatus*(
    stream: Stream, code: StatusV2
) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  trace "send stop relay/v2 status", status = $code & " (" & $ord(code) & ")"
  let msg =
    StopMessage(msgType: Opt.some(StopMessageType.Status), status: Opt.some(code))
  stream.writeLp(encode(msg))

proc bridge*(
    srcStream: Stream, dstStream: Stream
) {.async: (raises: [CancelledError]).} =
  const bufferSize = 4096
  var
    bufSrcToDst: array[bufferSize, byte]
    bufDstToSrc: array[bufferSize, byte]
    futSrc = srcStream.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
    futDst = dstStream.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
    bytesSentFromSrcToDst = 0
    bytesSentFromDstToSrc = 0
    bufRead: int

  try:
    while not srcStream.closed() and not dstStream.closed():
      try: # https://github.com/status-im/nim-chronos/issues/516
        discard await race(futSrc, futDst)
      except ValueError as e:
        raiseAssert("Futures list is not empty: " & e.msg)
      if futSrc.finished():
        bufRead = await futSrc
        if bufRead > 0:
          bytesSentFromSrcToDst.inc(bufRead)
          await dstStream.write(@bufSrcToDst[0 ..< bufRead])
          zeroMem(addr bufSrcToDst[0], bufSrcToDst.len)
        futSrc = srcStream.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
      if futDst.finished():
        bufRead = await futDst
        if bufRead > 0:
          bytesSentFromDstToSrc += bufRead
          await srcStream.write(bufDstToSrc[0 ..< bufRead])
          zeroMem(addr bufDstToSrc[0], bufDstToSrc.len)
        futDst = dstStream.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    if srcStream.closed() or srcStream.atEof():
      trace "relay src closed connection", src = srcStream.peerId
    if dstStream.closed() or dstStream.atEof():
      trace "relay dst closed connection", dst = dstStream.peerId
    trace "relay error", description = exc.msg
  trace "end relaying", bytesSentFromSrcToDst, bytesSentFromDstToSrc
  await futSrc.cancelAndWait()
  await futDst.cancelAndWait()

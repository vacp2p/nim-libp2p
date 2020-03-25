## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos
import nimcrypto/utils, chronicles
import types,
       ../../connection,
       ../../varint,
       ../../vbuffer,
       ../../stream/lpstream

logScope:
  topic = "MplexCoder"

const MaxFrameSize* = 1024 * 1024 # TODO + header - spec says this is max payload size!

type
  Msg* = tuple
    id: uint64
    msgType: MessageType
    data: seq[byte]

  InvalidMplexMsgType = object of CatchableError

proc newInvalidMplexMsgType*(): ref InvalidMplexMsgType =
  newException(InvalidMplexMsgType, "invalid message type")

proc readMsg*(conn: Connection): Future[Msg] {.async, gcsafe.} =
  let headerVarint = await conn.sb.readVarint()
  if headerVarint.isNone(): raise newLPStreamEOFError()

  let data = await conn.sb.readVarintMessage(MaxFrameSize)
  if data.isNone(): raise newLPStreamIncompleteError()

  let header = headerVarint.get()

  let msgType = header and 0x7
  if msgType.int > ord(MessageType.ResetOut):
    raise newInvalidMplexMsgType()

  result = (header shr 3, MessageType(msgType), data.get())
  trace "read mplex",
    id = result.id,
    msgType = result.msgType,
    data = shortLog(result.data)

proc writeMsg*(conn: Connection,
               id: uint64,
               msgType: MessageType,
               data: seq[byte] = @[]) {.async, gcsafe.} =
  trace "send mplex", id, msgType, data = shortLog(data)

  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writePBVarint(id shl 3 or ord(msgType).uint)
  buf.writePBVarint(data.len().uint) # size should be always sent
  buf.finish()
  try:
    await conn.write(buf.buffer & data)
  except LPStreamIncompleteError as exc:
    trace "unable to send message", exc = exc.msg

proc writeMsg*(conn: Connection,
               id: uint64,
               msgType: MessageType,
               data: string) {.async, gcsafe.} =
  result = conn.writeMsg(id, msgType, cast[seq[byte]](data))

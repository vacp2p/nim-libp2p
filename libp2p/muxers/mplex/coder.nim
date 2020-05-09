## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import nimcrypto/utils, chronicles
import types,
       ../../connection,
       ../../varint,
       ../../vbuffer,
       ../../stream/lpstream

logScope:
  topic = "MplexCoder"

type
  Msg* = tuple
    id: uint64
    msgType: MessageType
    data: seq[byte]

  InvalidMplexMsgType = object of CatchableError

proc newInvalidMplexMsgType*(): ref InvalidMplexMsgType =
  newException(InvalidMplexMsgType, "invalid message type")

proc readMplexVarint(conn: Connection): Future[uint64] {.async, gcsafe.} =
  var
    varint: uint
    length: int
    res: VarintStatus
    buffer = newSeq[byte](10)

  try:
    for i in 0..<len(buffer):
      await conn.readExactly(addr buffer[i], 1)
      res = PB.getUVarint(buffer.toOpenArray(0, i), length, varint)
      if res == VarintStatus.Success:
        break
    if res != VarintStatus.Success:
      raise newInvalidVarintException()
    return varint
  except LPStreamIncompleteError as exc:
    trace "unable to read varint", exc = exc.msg
    raise exc

proc readMsg*(conn: Connection): Future[Msg] {.async, gcsafe.} =
  let header = await conn.readMplexVarint()
  trace "read header varint", varint = header

  let dataLenVarint = await conn.readMplexVarint()
  trace "read data len varint", varint = dataLenVarint

  if dataLenVarint.int > DefaultReadSize:
    raise newInvalidVarintSizeException()

  var data: seq[byte] = newSeq[byte](dataLenVarint.int)
  if dataLenVarint.int > 0:
    await conn.readExactly(addr data[0], dataLenVarint.int)
    trace "read data", data = data.len

  let msgType = header and 0x7
  if msgType.int > ord(MessageType.ResetOut):
    raise newInvalidMplexMsgType()

  result = (uint64(header shr 3), MessageType(msgType), data)

proc writeMsg*(conn: Connection,
               id: uint64,
               msgType: MessageType,
               data: seq[byte] = @[]) {.async, gcsafe.} =
  trace "sending data over mplex", id,
                                  msgType,
                                  data = data.len
  var
      left = data.len
      offset = 0
  while left > 0 or data.len == 0:
    let
      chunkSize = if left > MaxMsgSize: MaxMsgSize - 64 else: left
      chunk = if chunkSize > 0 : data[offset..(offset + chunkSize - 1)] else: data
    ## write lenght prefixed
    var buf = initVBuffer()
    buf.writePBVarint(id shl 3 or ord(msgType).uint64)
    buf.writePBVarint(chunkSize.uint64) # size should be always sent
    buf.finish()
    left = left - chunkSize
    offset = offset + chunkSize
    try:
      await conn.write(buf.buffer & chunk)
    except LPStreamIncompleteError as exc:
      trace "unable to send message", exc = exc.msg
    if data.len == 0:
      return

proc writeMsg*(conn: Connection,
               id: uint64,
               msgType: MessageType,
               data: string) {.async, gcsafe.} =
  result = conn.writeMsg(id, msgType, cast[seq[byte]](data))

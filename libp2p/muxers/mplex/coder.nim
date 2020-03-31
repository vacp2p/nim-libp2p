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

const DefaultChannelSize* = 1 shl 20

type
  Msg* = tuple
    id: uint64
    msgType: MessageType
    data: seq[byte]

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
    if varint.int > DefaultReadSize:
      raise newInvalidVarintSizeException()
    return varint
  except LPStreamIncompleteError as exc:
    trace "unable to read varint", exc = exc.msg
    raise exc

proc readMsg*(conn: Connection): Future[Msg] {.async, gcsafe.} =
  let headerVarint = await conn.readMplexVarint()
  trace "read header varint", varint = headerVarint

  let dataLenVarint = await conn.readMplexVarint()
  trace "read data len varint", varint = dataLenVarint

  var data: seq[byte] = newSeq[byte](dataLenVarint.int)
  if dataLenVarint.int > 0:
    await conn.readExactly(addr data[0], dataLenVarint.int)
    trace "read data", data = data.len

  let header = headerVarint
  result = (uint64(header shr 3), MessageType(header and 0x7), data)

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

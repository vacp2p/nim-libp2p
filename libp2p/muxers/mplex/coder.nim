## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, options, sequtils, strformat
import types,  
       ../../connection, 
       ../../varint, 
       ../../vbuffer, 
       ../../stream/lpstream,
       nimcrypto/utils,
       ../../helpers/debug

type
  Msg* = tuple 
    id: uint 
    msgType: MessageType
    data: seq[byte]

proc readMplexVarint(conn: Connection): Future[Option[uint]] {.async, gcsafe.} =
  var
    varint: uint
    length: int
    res: VarintStatus
  var buffer = newSeq[byte](10)
  result = none(uint)
  try:
    for i in 0..<len(buffer):
      await conn.readExactly(addr buffer[i], 1)
      res = LP.getUVarint(buffer.toOpenArray(0, i), length, varint)
      if res == VarintStatus.Success:
        return some(varint)
    if res != VarintStatus.Success:
      buffer.setLen(0)
      return
  except TransportIncompleteError, AsyncStreamIncompleteError:
    buffer.setLen(0)

proc readMsg*(conn: Connection): Future[Option[Msg]] {.async, gcsafe.} = 
  let headerVarint = await conn.readMplexVarint()
  if headerVarint.isNone:
    return
  
  debug &"readMsg: read header varint {$headerVarint}"

  let dataLenVarint = await conn.readMplexVarint()
  var data: seq[byte]
  if dataLenVarint.isSome and dataLenVarint.get() > 0.uint:
    debug &"readMsg: read size varint {$dataLenVarint}"
    data = await conn.read(dataLenVarint.get().int)

  let header = headerVarint.get()
  result = some((header shr 3, MessageType(header and 0x7), data))

proc writeMsg*(conn: Connection,
               id: uint,
               msgType: MessageType, 
               data: seq[byte] = @[]) {.async, gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  let header = (id shl 3 or ord(msgType).uint)
  buf.writeVarint(id shl 3 or ord(msgType).uint)
  buf.writeVarint(data.len().uint) # size should be always sent
  buf.finish()
  await conn.write(buf.buffer & data)

proc writeMsg*(conn: Connection,
               id: uint,
               msgType: MessageType, 
               data: string) {.async, gcsafe.} =
  result = conn.writeMsg(id, msgType, cast[seq[byte]](toSeq(data.items)))
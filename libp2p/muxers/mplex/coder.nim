## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import types,  
       ../../connection, 
       ../../varint, 
       ../../vbuffer, 
       ../../stream/lpstream,
       nimcrypto/utils

type
  Phase = enum Header, Size

proc readMplexVarint(conn: Connection): Future[uint] {.async, gcsafe.} =
  var
    varint: uint
    length: int
    res: VarintStatus
  var buffer = newSeq[byte](10)
  try:
    for i in 0..<len(buffer):
      await conn.readExactly(addr buffer[i], 1)
      res = LP.getUVarint(buffer.toOpenArray(0, i), length, varint)
      if res == VarintStatus.Success:
        return varint
    if res != VarintStatus.Success:
      buffer.setLen(0)
      return
  except TransportIncompleteError, AsyncStreamIncompleteError:
    buffer.setLen(0)

proc readMsg*(conn: Connection): Future[(uint, MessageType, seq[byte])] {.async, gcsafe.} = 
  let header = await conn.readMplexVarint()
  let dataLen = await conn.readMplexVarint()
  var data: seq[byte]
  if dataLen > 0.uint:
    data = await conn.read(dataLen.int)
  result = (header shr 3, MessageType(header and 0x7), data)

proc writeMsg*(conn: Connection,
                  id: uint,
                  msgType: MessageType, 
                  data: seq[byte] = @[]) {.async, gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeVarint((id shl 3) or ord(msgType).uint)
  buf.writeVarint(data.len().uint) # size should be always sent
  buf.finish()
  await conn.write(buf.buffer & data)

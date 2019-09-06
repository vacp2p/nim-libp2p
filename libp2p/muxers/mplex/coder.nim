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

proc readHeader*(conn: Connection): Future[(uint, MessageType)] {.async, gcsafe.} = 
  var
    header: uint
    length: int
    res: VarintStatus
  var buffer = newSeq[byte](10)
  try:
    for i in 0..<len(buffer):
      await conn.readExactly(addr buffer[i], 1)
      res = LP.getUVarint(buffer.toOpenArray(0, i), length, header)
      if res == VarintStatus.Success:
        let (id, msg) = (header shr 3, MessageType(header and 0x7))
        return (header shr 3, MessageType(header and 0x7))
    if res != VarintStatus.Success:
      buffer.setLen(0)
      return
  except TransportIncompleteError:
    buffer.setLen(0)
    raise newLPStreamIncompleteError()

proc writeHeader*(conn: Connection,
                  id: int,
                  msgType: MessageType, 
                  size: int = 0) {.async, gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeVarint((id.uint shl 3) or msgType.uint)
  buf.writeVarint(size.uint) # size should be always sent
  buf.finish()
  await conn.write(buf.buffer)

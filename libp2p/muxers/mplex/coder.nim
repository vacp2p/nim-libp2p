## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../../connection, ../../varint, 
       ../../vbuffer, mplex, types,
       ../../stream/lpstream

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
        return (header shr 3, MessageType(header and 0x7))
    if res != VarintStatus.Success:
      buffer.setLen(0)
      return
  except LPStreamIncompleteError:
    buffer.setLen(0)

proc writeHeader*(conn: Connection,
                  id: int,
                  msgType: MessageType, 
                  size: int) {.async, gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeVarint(LPSomeUVarint(id.uint shl 3 or msgType.uint))
  if size > 0:
    buf.writeVarint(LPSomeUVarint(size.uint))
  buf.finish()
  result = conn.write(buf.buffer)

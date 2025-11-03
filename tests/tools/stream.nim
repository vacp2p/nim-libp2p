# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../../libp2p/stream/connection

proc newData*(size: int, val: byte = byte(0xFF)): seq[byte] =
  var data = newSeq[byte](size)
  for i in 0 ..< size:
    data[i] = val
  data

proc readStreamByChunkTillEOF*(
    stream: Connection, chunkSize: int, maxBytes: int = int.high
): Future[seq[byte]] {.async.} =
  ## Reads from stream until EOF is reached or the received data size meets/exceeds maxBytes
  var receivedData: seq[byte] = @[]

  while receivedData.len < maxBytes:
    var chunk = newSeq[byte](chunkSize)
    let bytesRead = await stream.readOnce(addr chunk[0], chunkSize)
    if bytesRead == 0:
      break
    receivedData.add(chunk[0 ..< bytesRead])

  receivedData

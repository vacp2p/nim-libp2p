# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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

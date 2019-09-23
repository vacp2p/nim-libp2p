## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import lpstream

logScope:
  topic = "ChronosStream"

type ChronosStream* = ref object of LPStream
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport

proc newChronosStream*(server: StreamServer, 
                       client: StreamTransport): ChronosStream =
  new result
  result.server = server
  result.client = client
  result.reader = newAsyncStreamReader(client)
  result.writer = newAsyncStreamWriter(client)
  result.closed = false

method read*(s: ChronosStream, n = -1): Future[seq[byte]] {.async, gcsafe.} = 
  try:
    result = await s.reader.read(n)
  except AsyncStreamReadError as exc:
    raise newLPStreamReadError(exc.par)

method readExactly*(s: ChronosStream, 
                    pbytes: pointer, 
                    nbytes: int): Future[void] {.async, gcsafe.} =
  try:
    await s.reader.readExactly(pbytes, nbytes)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamReadError as exc:
    raise newLPStreamReadError(exc.par)

method readLine*(s: ChronosStream, limit = 0, sep = "\r\n"): Future[string] {.async, gcsafe.} =
    try:
      result = await s.reader.readLine(limit, sep)
    except AsyncStreamReadError as exc:
      raise newLPStreamReadError(exc.par)

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async, gcsafe.} =
    try:
      result = await s.reader.readOnce(pbytes, nbytes)
    except AsyncStreamReadError as exc:
      raise newLPStreamReadError(exc.par)

method readUntil*(s: ChronosStream, 
                  pbytes: pointer, 
                  nbytes: int, 
                  sep: seq[byte]): Future[int] {.async, gcsafe.} =
  try:
    result = await s.reader.readUntil(pbytes, nbytes, sep)
  except TransportIncompleteError, AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except TransportLimitError, AsyncStreamLimitError:
    raise newLPStreamLimitError()
  except LPStreamReadError as exc:
    raise newLPStreamReadError(exc.par)

method write*(s: ChronosStream, pbytes: pointer, nbytes: int) {.async, gcsafe.} =
  try:
    await s.writer.write(pbytes, nbytes)
  except AsyncStreamWriteError as exc:
    raise newLPStreamWriteError(exc.par)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()

method write*(s: ChronosStream, msg: string, msglen = -1) {.async, gcsafe.} =
  try:
    await s.writer.write(msg, msglen)
  except AsyncStreamWriteError as exc:
    raise newLPStreamWriteError(exc.par)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()

method write*(s: ChronosStream, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  try:
    await s.writer.write(msg, msglen)
  except AsyncStreamWriteError as exc:
    raise newLPStreamWriteError(exc.par)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()

method close*(s: ChronosStream) {.async, gcsafe.} =
  if not s.closed:
    trace "closing connection for", address = $s.client.remoteAddress()
    if not s.reader.closed:
      await s.reader.closeWait()

    await s.writer.finish()
    if not s.writer.closed:
      await s.writer.closeWait()

    if not s.client.closed:
      await s.client.closeWait()
    
    s.closed = true
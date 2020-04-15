## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# {.push raises: [].}

import chronos, chronicles
import stream

logScope:
  topic = "ChronosStream"

const DefaultChunkSize* = 1 shl 20 # 1MB

type ChronosStream* = ref object of Stream
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport
    eof: bool
    buffer: seq[byte]
    maxChunkSize: int

proc init*(C: type[ChronosStream],
           server: StreamServer,
           client: StreamTransport,
           maxChunkSize = DefaultChunkSize): C =

  ChronosStream(server: server,
                client: client,
                reader: newAsyncStreamReader(client),
                writer: newAsyncStreamWriter(client),
                maxChunkSize: maxChunkSize,
                buffer: newSeq[byte](maxChunkSize))

proc internalRead(c: ChronosStream): Future[seq[byte]] {.async.} =
  var read = await c.reader.readOnce(addr c.buffer[0], c.buffer.len)
  if read <= 0:
    c.eof = true
    return

  result = c.buffer[0..<read]

method source*(c: ChronosStream): Source[seq[byte]] =
  return iterator(): Future[seq[byte]] =
    while not c.atEof():
      yield c.internalRead()
      echo c.buffer

method sink*(c: ChronosStream): Sink[seq[byte]] =
  return proc(i: Source[seq[byte]]) {.async.} =
    for chunk in i:
      if c.closed:
        break

      # sadly `await c.writer.write((await chunk))` breaks
      var cchunk = await chunk
      await c.writer.write(cchunk)

proc close*(c: ChronosStream) {.async.} =
  if not c.closed:
    trace "shutting chronos stream", address = $c.client.remoteAddress()
    if not c.writer.closed():
      await c.writer.closeWait()

    if not c.reader.closed():
      await c.reader.closeWait()

    if not c.client.closed():
      await c.client.closeWait()

  c.isClosed = true

proc atEof*(c: ChronosStream): bool =
  c.eof

# {.pop.}

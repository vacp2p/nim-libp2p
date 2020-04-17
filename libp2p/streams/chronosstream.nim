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

const
  DefaultChunkSize* = 1 shl 20 # 1MB
  EofTag: seq[byte] = @[]

type ChronosStream* = ref object of Stream[seq[byte]]
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport
    buffer: seq[byte]
    maxChunkSize: int

proc close*(c: ChronosStream) {.async.} =
  if not c.atEof:
    trace "shutting chronos stream", address = $c.client.remoteAddress()
    if not c.writer.closed():
      await c.writer.closeWait()

    if not c.reader.closed():
      await c.reader.closeWait()

    if not c.client.closed():
      await c.client.closeWait()

  c.eof = true

proc internalRead(c: ChronosStream): Future[seq[byte]] {.async.} =
  var read = await c.reader.readOnce(addr c.buffer[0], c.buffer.len)
  if read <= 0:
    c.eof = true
    return

  result = c.buffer[0..<read]

proc onEof(c: ChronosStream): Future[seq[byte]] {.async.} =
  await c.close()
  result = EofTag

proc chronosSource(s: Stream[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return iterator(): Future[seq[byte]] =
    while not c.atEof:
      yield c.internalRead()
    yield c.onEof() # propagate eof

proc chronosSink(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return proc(i: Source[seq[byte]]) {.async.} =
    for chunk in i:
      # sadly `await c.writer.write((await chunk))` breaks
      var cchunk = await chunk
      await c.writer.write(cchunk)

      if c.atEof:
        await c.close()
        return

proc init*(C: type[ChronosStream],
           server: StreamServer,
           client: StreamTransport,
           maxChunkSize = DefaultChunkSize): C =

  ChronosStream(server: server,
                client: client,
                reader: newAsyncStreamReader(client),
                writer: newAsyncStreamWriter(client),
                maxChunkSize: maxChunkSize,
                buffer: newSeq[byte](maxChunkSize), # TODO: grow dynamicaly
                sourceImpl: chronosSource,
                sinkImpl: chronosSink,
                name: "ChronosStream")

# {.pop.}

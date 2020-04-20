## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# {.push raises: [].}

import chronos, chronicles, stew/byteutils
import stream

logScope:
  topic = "ChronosStream"

const
  DefaultChunkSize* = 1 shl 20 # 1MB
  EofTag: seq[byte] = @[]

type
  ChronosStream* = ref object of Stream[seq[byte]]
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

proc onEof(c: ChronosStream): Future[seq[byte]] {.async.} =
  await c.close()
  c.eof = true
  result = EofTag

proc read(c: ChronosStream): Future[seq[byte]] {.async.} =
  var read = 0
  if not c.reader.atEof:
    read = await c.reader.readOnce(addr c.buffer[0], c.buffer.len)

  if read <= 0:
    return await c.onEof()

  result = c.buffer[0..<read]

proc chronosSource(s: Stream[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return iterator(): Future[seq[byte]] =
    if c.atEof:
      raise newStreamEofError()

    while true:
      var res = c.read()
      if c.atEof:
        break
      yield res

proc chronosSink(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return proc(i: Source[seq[byte]]) {.async.} =
    if c.atEof:
      raise newStreamEofError()

    for chunk in i:
      var cchunk = await chunk
      if cchunk.len <= 0:
        break

      await c.writer.write(cchunk)

    trace "sink ended, clenaning up"
    # TODO: Should `sink` close the entire
    # chronos stream or just the writer?
    # Ssame question goes for the `source`.
    # discard await c.onEof()

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

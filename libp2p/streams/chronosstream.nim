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

proc atEof*(c: ChronosStream): bool =
  c.eof

proc close*(c: ChronosStream) {.async.} =
  if not c.atEof:
    c.eof = true
    trace "shutting chronos stream", address = $c.client.remoteAddress()
    if not c.writer.closed():
      await c.writer.closeWait()

    if not c.reader.closed():
      await c.reader.closeWait()

    if not c.client.closed():
      await c.client.closeWait()

proc onEof(c: ChronosStream) {.async.} =
  await c.close()

proc read(c: ChronosStream): Future[seq[byte]] {.async.} =
  var read = 0
  if not c.reader.atEof:
    read = await c.reader.readOnce(addr c.buffer[0], c.buffer.len)

  if read <= 0:
    await c.onEof()
    return

  result = c.buffer[0..<read]
  echo "READ ", result

proc chronosSource(s: Stream[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return iterator(): Future[seq[byte]] =
    if c.atEof:
      raise newStreamEofError()

    while not c.atEof:
      echo "READING"
      yield c.read()

proc chronosSink(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  var stack = getStackTrace()
  return proc(i: Source[seq[byte]]) {.async.} =
    if c.atEof:
      raise newStreamEofError()

    for chunk in i:
      var cchunk = await chunk
      if cchunk.len <= 0:
        break

      echo "WRITTING"
      await c.writer.write(cchunk)

    echo stack
    trace "sink ended, clenaning up"
    await c.onEof()

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

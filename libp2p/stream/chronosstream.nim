## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import stream

logScope:
  topic = "ChronosStream"

const DefaultChunkSize* = 1 shl 20 # 1MB

type ChronosStream* = ref object of Stream[seq[byte]]
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport
    maxChunkSize: int

proc init*(c: type[ChronosStream],
           server: StreamServer,
           client: StreamTransport,
           maxChunkSize = DefaultChunkSize): c =

  ChronosStream(server: server,
                client: client,
                reader: newAsyncStreamReader(client),
                writer: newAsyncStreamWriter(client),
                maxChunkSize)

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
  c.reader.atEof()

proc source*(c: ChronosStream,
             size: int = c.maxChunkSize): Source[seq[byte]] =
  return iterator(): Future[seq[byte]] =
    while not c.reader.atEof():
        yield c.reader.read(c.maxChunkSize)

proc sink*(c: ChronosStream): Sink[seq[byte]] =
  return proc(i: Source[seq[byte]]): Future[void] {.async.} =
    for chunk in i:
      if c.closed:
        break

      await c.writer.write((await chunk))

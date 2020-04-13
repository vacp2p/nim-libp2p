## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles

logScope:
  topic = "ChronosStream"

const DefaultChunkSize* = 1 shl 20 # 1MB

type ChronosStream* = ref object
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    server: StreamServer
    client: StreamTransport
    maxChunkSize: int
    closed: bool

proc init*[T](c: type[ChronosStream],
              server: StreamServer,
              client: StreamTransport,
              maxChunkSize = DefaultChunkSize): c =

  ChronosStream(server: server,
                client: client,
                reader: newAsyncStreamReader(client),
                writer: newAsyncStreamWriter(client),
                maxChunkSize)

proc close*(c: ChronosStream) =
  c.closed = true

iterator source*(c: ChronosStream, size: int = c.maxChunkSize): Future[seq[byte]] =
  while not c.reader.atEof():
      yield c.reader.read(c.maxChunkSize)

proc sink*(c: ChronosStream,
          iter: iterator(): Future[seq[byte]]):
          Future[void] {.async.}=
  for chunk in iter():
    if c.closed:
      break

    await c.writer.write((await chunk))

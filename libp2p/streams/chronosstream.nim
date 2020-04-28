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

type
  ChronosStream* = ref object of Stream[seq[byte]]
    socket: StreamTransport
    buffer: seq[byte]
    maxChunkSize: int

proc close*(c: ChronosStream) {.async.} =
  if not c.atEof:
    c.eof = true
    trace "shutting chronos stream", address = $c.socket.remoteAddress()
    if not c.socket.closed():
      await c.socket.closeWait()

proc read(c: ChronosStream): Future[seq[byte]] {.async.} =
  var read = 0
  if not c.socket.atEof:
    read = await c.socket.readOnce(addr c.buffer[0], c.buffer.len)

  if read <= 0:
    return

  result = c.buffer[0..<read]

proc chronosSource(s: Stream[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return iterator(abort: bool = false): Future[seq[byte]] =
    while not c.atEof and not abort:
      yield c.read()

proc chronosSink(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
  var c = ChronosStream(s)
  return proc(i: Source[seq[byte]]) {.async.} =
    if c.atEof:
      raise newStreamEofError()

    for chunk in i(c.atEof):
      var cchunk = await chunk
      if cchunk.len <= 0:
        break

      var writen = 0
      while writen < cchunk.len:
        writen += await c.socket.write(cchunk)

    trace "sink ended, clenaning up"
    await c.close()

proc init*(C: type[ChronosStream],
           server: StreamServer,
           socket: StreamTransport,
           maxChunkSize = DefaultChunkSize): C =
  ChronosStream(socket: socket,
                maxChunkSize: maxChunkSize,
                buffer: newSeq[byte](maxChunkSize), # TODO: grow dynamicaly
                sourceImpl: chronosSource,
                sinkImpl: chronosSink,
                name: "ChronosStream")

# {.pop.}

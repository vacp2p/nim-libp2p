## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import readerwriter

type ChronosStream* = ref object of ReadWrite
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

method read*(s: ChronosStream, n = -1): Future[seq[byte]] {.async.} = 
  result = await s.reader.read(n)

method readExactly*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[void] {.async.} =
  result = s.readExactly(pbytes, nbytes)

method readLine*(s: ChronosStream, limit = 0, sep = "\r\n"): Future[string] {.async.} =
  result = await s.reader.readLine(limit, sep)

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  result = await s.reader.readOnce(pbytes, nbytes)

method readUntil*(s: ChronosStream, pbytes: pointer, nbytes: int, sep: seq[byte]): Future[int] {.async.} =
  result = await s.reader.readUntil(pbytes, nbytes, sep)

method write*(s: ChronosStream, pbytes: pointer, nbytes: int) {.async.} =
  result = s.writer.write(pbytes, nbytes)

method write*(s: ChronosStream, msg: string, msglen = -1) {.async.} =
  result = s.writer.write(msg, msglen)

method write*(s: ChronosStream, msg: seq[byte], msglen = -1) {.async.} =
  result = s.writer.write(msg, msglen)

method close*(s: ChronosStream) {.async.} =
  await s.reader.closeWait()

  await s.writer.finish()
  await s.writer.closeWait()

  await s.client.closeWait()
  s.server.stop()
  s.server.close()

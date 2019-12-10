## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
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
  result.closeEvent = newAsyncEvent()

method read*(s: ChronosStream, n = -1): Future[seq[byte]] {.async.} =
  if s.reader.atEof:
    raise newLPStreamEOFError()

  try:
    result = await s.reader.read(n)
  except AsyncStreamReadError as exc:
    raise newLPStreamReadError(exc.par)
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method readExactly*(s: ChronosStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] {.async.} =
  if s.reader.atEof:
    raise newLPStreamEOFError()

  try:
    await s.reader.readExactly(pbytes, nbytes)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamReadError as exc:
    raise newLPStreamReadError(exc.par)
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method readLine*(s: ChronosStream, limit = 0, sep = "\r\n"): Future[string] {.async.} =
  if s.reader.atEof:
    raise newLPStreamEOFError()

  try:
    result = await s.reader.readLine(limit, sep)
  except AsyncStreamReadError as exc:
    raise newLPStreamReadError(exc.par)
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.reader.atEof:
    raise newLPStreamEOFError()

  try:
    result = await s.reader.readOnce(pbytes, nbytes)
  except AsyncStreamReadError as exc:
    raise newLPStreamReadError(exc.par)
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method readUntil*(s: ChronosStream,
                  pbytes: pointer,
                  nbytes: int,
                  sep: seq[byte]): Future[int] {.async.} =
  if s.reader.atEof:
    raise newLPStreamEOFError()

  try:
    result = await s.reader.readUntil(pbytes, nbytes, sep)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamLimitError:
    raise newLPStreamLimitError()
  except LPStreamReadError as exc:
    raise newLPStreamReadError(exc.par)
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method write*(s: ChronosStream, pbytes: pointer, nbytes: int) {.async.} =
  if s.writer.atEof:
    raise newLPStreamEOFError()

  try:
    await s.writer.write(pbytes, nbytes)
  except AsyncStreamWriteError as exc:
    raise newLPStreamWriteError(exc.par)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method write*(s: ChronosStream, msg: string, msglen = -1) {.async.} =
  if s.writer.atEof:
    raise newLPStreamEOFError()

  try:
    await s.writer.write(msg, msglen)
  except AsyncStreamWriteError as exc:
    raise newLPStreamWriteError(exc.par)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method write*(s: ChronosStream, msg: seq[byte], msglen = -1) {.async.} =
  if s.writer.atEof:
    raise newLPStreamEOFError()

  try:
    await s.writer.write(msg, msglen)
  except AsyncStreamWriteError as exc:
    raise newLPStreamWriteError(exc.par)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()
  except AsyncStreamIncorrectError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method closed*(s: ChronosStream): bool {.inline.} =
  # TODO: we might only need to check for reader's EOF
  result = s.reader.atEof()

method close*(s: ChronosStream) {.async.} =
  if not s.closed:
    trace "shutting chronos stream", address = $s.client.remoteAddress()
    if not s.writer.closed():
      await s.writer.closeWait()

    if not s.reader.closed():
      await s.reader.closeWait()

    if not s.client.closed():
      await s.client.closeWait()

    s.closeEvent.fire()

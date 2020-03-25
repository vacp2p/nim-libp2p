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
export lpstream

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
  initLPStream(result)
  result.server = server
  result.client = client
  result.reader = newAsyncStreamReader(client)
  result.writer = newAsyncStreamWriter(client)

template withExceptions(body: untyped) =
  try:
    body
  except TransportIncompleteError:
    raise newLPStreamIncompleteError()
  except TransportLimitError:
    raise newLPStreamLimitError()
  except TransportError as exc:
    raise newLPStreamIncorrectError(exc.msg)
  except AsyncStreamIncompleteError:
    raise newLPStreamIncompleteError()

method readOnce*(s: ChronosStream): Future[seq[byte]] {.async, gcsafe.} =
  if s.reader.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    var tmp = newSeq[byte](1024)
    let bytes = await s.reader.readOnce(addr tmp[0], tmp.len)
    tmp.setLen(bytes)
    return tmp

method write*(s: ChronosStream, msg: seq[byte], msglen = -1) {.async.} =
  if s.writer.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    await s.writer.write(msg, msglen)

method closed*(s: ChronosStream): bool {.inline.} =
  # TODO: we might only need to check for reader's EOF
  result = s.reader.atEof()

method close*(s: ChronosStream) {.async.} =
  if not s.closed:
    s.isClosed = true

    trace "shutting chronos stream", address = $s.client.remoteAddress()
    if not s.writer.closed():
      await s.writer.closeWait()

    if not s.reader.closed():
      await s.reader.closeWait()

    if not s.client.closed():
      await s.client.closeWait()

    s.closeEvent.fire()

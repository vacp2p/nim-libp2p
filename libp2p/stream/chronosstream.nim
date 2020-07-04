## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import connection, ../utility

logScope:
  topics = "chronosstream"

type ChronosStream* = ref object of Connection
    client: StreamTransport

method initStream*(s: ChronosStream) =
  if s.objName.len == 0:
    s.objName = "ChronosStream"

  procCall Connection(s).initStream()

proc newChronosStream*(client: StreamTransport): ChronosStream =
  new result
  result.client = client
  result.initStream()

template withExceptions(body: untyped) =
  try:
    body
  except TransportIncompleteError:
    # for all intents and purposes this is an EOF
    raise newLPStreamEOFError()
  except TransportLimitError:
    raise newLPStreamLimitError()
  except TransportUseClosedError:
    raise newLPStreamEOFError()
  except TransportError:
    # TODO https://github.com/status-im/nim-chronos/pull/99
    raise newLPStreamEOFError()
    # raise (ref LPStreamError)(msg: exc.msg, parent: exc)

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    result = await s.client.readOnce(pbytes, nbytes)

method write*(s: ChronosStream, msg: seq[byte]) {.async.} =
  if s.closed:
    raise newLPStreamClosedError()

  if msg.len == 0:
    return

  withExceptions:
    var written = 0
    while not s.client.closed and written < msg.len:
      written += await s.client.write(msg[written..<msg.len])

    if written < msg.len:
      raise (ref LPStreamClosedError)(msg: "Write couldn't finish writing")

method closed*(s: ChronosStream): bool {.inline.} =
  result = s.client.closed

method atEof*(s: ChronosStream): bool {.inline.} =
  s.client.atEof()

method close*(s: ChronosStream) {.async.} =
  try:
    if not s.isClosed:
      await procCall Connection(s).close()

      trace "shutting down chronos stream", address = $s.client.remoteAddress(), oid = s.oid
      if not s.client.closed():
        await s.client.closeWait()

  except CatchableError as exc:
    trace "error closing chronosstream", exc = exc.msg

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
  topic = "ChronosStream"

type ChronosStream* = ref object of Connection
    client: StreamTransport

proc newChronosStream*(client: StreamTransport): ChronosStream =
  new result
  result.client = client
  result.closeEvent = newAsyncEvent()

template withExceptions(body: untyped) =
  try:
    body
  except TransportIncompleteError:
    raise newLPStreamIncompleteError()
  except TransportLimitError:
    raise newLPStreamLimitError()
  except TransportUseClosedError:
    raise newLPStreamEOFError()
  except TransportError:
    # TODO https://github.com/status-im/nim-chronos/pull/99
    raise newLPStreamEOFError()
    # raise (ref LPStreamError)(msg: exc.msg, parent: exc)

method read*(s: ChronosStream, n: int = -1): Future[seq[byte]] {.async.} =
  if s.client.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    result = await s.client.read()

method readExactly*(s: ChronosStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] {.async.} =
  if s.client.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    await s.client.readExactly(pbytes, nbytes)

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.client.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    result = await s.client.readOnce(pbytes, nbytes)

method write*(s: ChronosStream, msg: seq[byte]) {.async.} =
  if msg.len == 0:
    return

  withExceptions:
    # Returns 0 sometimes when write fails - but there's not much we can do here?
    if (await s.client.write(msg)) != msg.len:
      raise (ref LPStreamError)(msg: "Write couldn't finish writing")

method closed*(s: ChronosStream): bool {.inline.} =
  result = s.client.closed

method close*(s: ChronosStream) {.async.} =
  if not s.closed:
    trace "shutting chronos stream", address = $s.client.remoteAddress()
    if not s.client.closed():
      await s.client.closeWait()

    s.closeEvent.fire()

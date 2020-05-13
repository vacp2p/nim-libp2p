## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import lpstream, ../utility

logScope:
  topic = "ChronosStream"

type ChronosStream* = ref object of LPStream
    client: StreamTransport

proc onTransportClose(s: ChronosStream,
                      client: StreamTransport) {.async.} =
  await client.join()
  trace "Transport closed, closing connection"
  await s.close()

proc newChronosStream*(client: StreamTransport): ChronosStream =
  new result
  result.client = client
  result.closeEvent = newAsyncEvent()

  asyncCheck result.onTransportClose(result.client)

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

method readExactly*(s: ChronosStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] {.async.} =
  if s.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    await s.client.readExactly(pbytes, nbytes)

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
    var writen = 0
    while (writen < msg.len):
      writen += await s.client.write(msg[writen..<msg.len]) # TODO: does the slice create a copy here?

method closed*(s: ChronosStream): bool {.inline.} =
  result = s.client.closed

method atEof*(s: ChronosStream): bool {.inline.} =
  s.client.atEof()

method close*(s: ChronosStream) {.async.} =
  if not s.closed:
    trace "shutting chronos stream", address = $s.client.remoteAddress()
    if not s.client.closed():
      try:
        await s.client.closeWait()
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        # Shouldn't happen, but we can't be sure
        warn "error while closing connection", msg = exc.msg

    s.closeEvent.fire()

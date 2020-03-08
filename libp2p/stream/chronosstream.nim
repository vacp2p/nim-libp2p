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
    server: StreamServer
    client: StreamTransport

proc newChronosStream*(server: StreamServer,
                       client: StreamTransport): ChronosStream =
  new result
  result.server = server
  result.client = client
  result.closeEvent = newAsyncEvent()

template withExceptions(body: untyped) =
  try:
    body
  except TransportIncompleteError:
    raise newLPStreamIncompleteError()
  except TransportLimitError:
    raise newLPStreamLimitError()
  except TransportError as exc:
    raise newLPStreamIncorrectError(exc.msg)

method read*(s: ChronosStream, n = -1): Future[seq[byte]] {.async.} =
  withExceptions:
    result = await s.client.read(n)

method readExactly*(s: ChronosStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] {.async.} =
  withExceptions:
    await s.client.readExactly(pbytes, nbytes)

method readLine*(s: ChronosStream, limit = 0, sep = "\r\n"): Future[string] {.async.} =
  withExceptions:
    result = await s.client.readLine(limit, sep)

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  withExceptions:
    result = await s.client.readOnce(pbytes, nbytes)

method readUntil*(s: ChronosStream,
                  pbytes: pointer,
                  nbytes: int,
                  sep: seq[byte]): Future[int] {.async.} =
  withExceptions:
    result = await s.client.readUntil(pbytes, nbytes, sep)

method write*(s: ChronosStream, pbytes: pointer, nbytes: int) {.async.} =
  withExceptions:
    discard await s.client.write(pbytes, nbytes)

method write*(s: ChronosStream, msg: string, msglen = -1) {.async.} =
  withExceptions:
    # TODO do something about return value here
    discard await s.client.write(msg, msglen)

method write*(s: ChronosStream, msg: seq[byte], msglen = -1) {.async.} =
  withExceptions:
    discard await s.client.write(msg, msglen)

method closed*(s: ChronosStream): bool {.inline.} =
  # TODO: we might only need to check for reader's EOF
  result = s.client.closed()

method close*(s: ChronosStream) {.async.} =
  if not s.closed:
    trace "shutting chronos stream", address = $s.client.remoteAddress()
    if not s.client.closed():
      await s.client.closeWait()

    s.closeEvent.fire()

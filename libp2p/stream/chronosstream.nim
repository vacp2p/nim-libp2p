## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[oids, strformat]
import chronos, chronicles
import connection

logScope:
  topics = "chronosstream"

const
  DefaultChronosStreamTimeout = 10.minutes
  ChronosStreamTrackerName* = "ChronosStream"

type
  ChronosStream* = ref object of Connection
    client: StreamTransport

func shortLog*(conn: ChronosStream): string =
  if conn.isNil: "ChronosStream(nil)"
  elif conn.peerInfo.isNil: $conn.oid
  else: &"{shortLog(conn.peerInfo.peerId)}:{conn.oid}"
chronicles.formatIt(ChronosStream): shortLog(it)

method initStream*(s: ChronosStream) =
  if s.objName.len == 0:
    s.objName = "ChronosStream"

  s.timeoutHandler = proc() {.async, gcsafe.} =
    trace "Idle timeout expired, closing ChronosStream", s
    await s.close()

  procCall Connection(s).initStream()

proc init*(C: type ChronosStream,
           client: StreamTransport,
           dir: Direction,
           timeout = DefaultChronosStreamTimeout): ChronosStream =
  result = C(client: client,
             timeout: timeout,
             dir: dir)
  result.initStream()

template withExceptions(body: untyped) =
  try:
    body
  except CancelledError as exc:
    raise exc
  except TransportIncompleteError:
    # for all intents and purposes this is an EOF
    raise newLPStreamIncompleteError()
  except TransportLimitError:
    raise newLPStreamLimitError()
  except TransportUseClosedError:
    raise newLPStreamEOFError()
  except TransportError:
    # TODO https://github.com/status-im/nim-chronos/pull/99
    raise newLPStreamEOFError()

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    result = await s.client.readOnce(pbytes, nbytes)
    s.activity = true # reset activity flag

method write*(s: ChronosStream, msg: seq[byte]) {.async.} =
  if s.closed:
    raise newLPStreamClosedError()

  if msg.len == 0:
    return

  withExceptions:
    # StreamTransport will only return written < msg.len on fatal failures where
    # further writing is not possible - in such cases, we'll raise here,
    # since we don't return partial writes lengths
    var written = await s.client.write(msg)

    if written < msg.len:
      raise (ref LPStreamClosedError)(msg: "Write couldn't finish writing")

    s.activity = true # reset activity flag

method closed*(s: ChronosStream): bool {.inline.} =
  result = s.client.closed

method atEof*(s: ChronosStream): bool {.inline.} =
  s.client.atEof()

method closeImpl*(s: ChronosStream) {.async.} =
  try:
    trace "Shutting down chronos stream", address = $s.client.remoteAddress(),
                                          s
    if not s.client.closed():
      await s.client.closeWait()

    trace "Shutdown chronos stream", address = $s.client.remoteAddress(),
                                     s

  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Error closing chronosstream", s, msg = exc.msg

  await procCall Connection(s).closeImpl()

# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[strformat]
import stew/results
import chronos, chronicles, metrics
import connection
import ../utility

export results

logScope:
  topics = "libp2p chronosstream"

const
  DefaultChronosStreamTimeout = 10.minutes
  ChronosStreamTrackerName* = "ChronosStream"

type
  ChronosStream* = ref object of Connection
    client: StreamTransport
    when defined(libp2p_agents_metrics):
      tracked: bool

when defined(libp2p_agents_metrics):
  declareGauge libp2p_peers_identity,
    "peers identities", labels = ["agent"]
  declareCounter libp2p_peers_traffic_read,
    "incoming traffic", labels = ["agent"]
  declareCounter libp2p_peers_traffic_write,
    "outgoing traffic", labels = ["agent"]

declareCounter libp2p_network_bytes,
  "total traffic", labels = ["direction"]

func shortLog*(conn: ChronosStream): auto =
  try:
    if conn == nil: "ChronosStream(nil)"
    else: &"{shortLog(conn.peerId)}:{conn.oid}"
  except ValueError as exc:
    raiseAssert(exc.msg)

chronicles.formatIt(ChronosStream): shortLog(it)

method initStream*(s: ChronosStream) =
  if s.objName.len == 0:
    s.objName = ChronosStreamTrackerName

  s.timeoutHandler = proc(): Future[void] {.async: (raises: [], raw: true).} =
    trace "Idle timeout expired, closing ChronosStream", s
    s.close()

  procCall Connection(s).initStream()

proc init*(
    C: type ChronosStream,
    client: StreamTransport,
    dir: Direction,
    timeout = DefaultChronosStreamTimeout,
    observedAddr: Opt[MultiAddress]): ChronosStream =
  result = C(client: client,
             timeout: timeout,
             dir: dir,
             observedAddr: observedAddr)
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

when defined(libp2p_agents_metrics):
  proc trackPeerIdentity(s: ChronosStream) =
    if not s.tracked and s.shortAgent.len > 0:
      libp2p_peers_identity.inc(labelValues = [s.shortAgent])
      s.tracked = true

  proc untrackPeerIdentity(s: ChronosStream) =
    if s.tracked:
      libp2p_peers_identity.dec(labelValues = [s.shortAgent])
      s.tracked = false

method readOnce*(
    s: ChronosStream,
    pbytes: pointer,
    nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  if s.atEof:
    raise newLPStreamEOFError()
  withExceptions:
    result = await s.client.readOnce(pbytes, nbytes)
    s.activity = true # reset activity flag
    libp2p_network_bytes.inc(result.int64, labelValues = ["in"])
    when defined(libp2p_agents_metrics):
      s.trackPeerIdentity()
      if s.tracked:
        libp2p_peers_traffic_read.inc(result.int64, labelValues = [s.shortAgent])

proc completeWrite(
    s: ChronosStream,
    fut: Future[int].Raising([TransportError, CancelledError]),
    msgLen: int
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  withExceptions:
    # StreamTransport will only return written < msg.len on fatal failures where
    # further writing is not possible - in such cases, we'll raise here,
    # since we don't return partial writes lengths
    var written = await fut

    if written < msgLen:
      raise (ref LPStreamClosedError)(msg: "Write couldn't finish writing")

    s.activity = true # reset activity flag
    libp2p_network_bytes.inc(msgLen.int64, labelValues = ["out"])
    when defined(libp2p_agents_metrics):
      s.trackPeerIdentity()
      if s.tracked:
        libp2p_peers_traffic_write.inc(msgLen.int64, labelValues = [s.shortAgent])

method write*(
    s: ChronosStream,
    msg: seq[byte]
): Future[void] {.async: (raises: [
    CancelledError, LPStreamError], raw: true).} =
  # Avoid a copy of msg being kept in the closure created by `{.async.}` as this
  # drives up memory usage
  if msg.len == 0:
    trace "Empty byte seq, nothing to write"
    let fut = newFuture[void]("chronosstream.write.empty")
    fut.complete()
    return fut
  if s.closed:
    let fut = newFuture[void]("chronosstream.write.closed")
    fut.fail(newLPStreamClosedError())
    return fut

  s.completeWrite(s.client.write(msg), msg.len)

method closed*(s: ChronosStream): bool =
  s.client.closed

method atEof*(s: ChronosStream): bool =
  s.client.atEof()

method closeImpl*(
    s: ChronosStream) {.async: (raises: []).} =
  trace "Shutting down chronos stream", address = $s.client.remoteAddress(), s

  if not s.client.closed():
    await s.client.closeWait()

  trace "Shutdown chronos stream", address = $s.client.remoteAddress(), s

  when defined(libp2p_agents_metrics):
    # do this after closing!
    s.untrackPeerIdentity()

  await procCall Connection(s).closeImpl()

method getWrapped*(s: ChronosStream): Connection = nil

## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[oids, strformat, strutils]
import chronos, chronicles, metrics
import connection

logScope:
  topics = "chronosstream"

const
  DefaultChronosStreamTimeout = 10.minutes
  ChronosStreamTrackerName* = "ChronosStream"

type
  ChronosStream* = ref object of Connection
    client: StreamTransport
    tracked: bool

declareGauge(libp2p_peers_identity, "peers identities", labels = ["agent"])

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
           timeout = DefaultChronosStreamTimeout,
           observedAddr: MultiAddress = MultiAddress()): ChronosStream =
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

proc trackPeerIdentity(s: ChronosStream) =
  if not s.tracked:
    if not isNil(s.peerInfo) and s.peerInfo.agentVersion.len > 0:
      # / seems a weak "standard" so for now it's reliable
      let name = s.peerInfo.agentVersion.split("/")[0]
      libp2p_peers_identity.inc(labelValues = [name])
      s.tracked = true

proc untrackPeerIdentity(s: ChronosStream) =
  if s.tracked:
    if not isNil(s.peerInfo) and s.peerInfo.agentVersion.len > 0:
      let name = s.peerInfo.agentVersion.split("/")[0]
      libp2p_peers_identity.dec(labelValues = [name])
      s.tracked = false

method readOnce*(s: ChronosStream, pbytes: pointer, nbytes: int): Future[int] {.async.} =
  if s.atEof:
    raise newLPStreamEOFError()

  withExceptions:
    s.trackPeerIdentity()
    
    result = await s.client.readOnce(pbytes, nbytes)
    s.activity = true # reset activity flag

method write*(s: ChronosStream, msg: seq[byte]) {.async.} =
  if s.closed:
    raise newLPStreamClosedError()

  if msg.len == 0:
    return

  withExceptions:
    s.trackPeerIdentity()

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
    trace "Shutting down chronos stream", address = $s.client.remoteAddress(), s
    
    s.untrackPeerIdentity()

    if not s.client.closed():
      await s.client.closeWait()

    trace "Shutdown chronos stream", address = $s.client.remoteAddress(),
                                     s

  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Error closing chronosstream", s, msg = exc.msg

  await procCall Connection(s).closeImpl()

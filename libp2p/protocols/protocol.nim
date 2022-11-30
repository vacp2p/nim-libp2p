# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/tables
import chronos, chronicles
import ../stream/connection

logScope:
  topics = "libp2p protocol"

const
  DefaultMaxIncomingStreams* = 10

type
  LPProtoHandler* = proc (
    conn: Connection,
    proto: string):
    Future[void]
    {.gcsafe, raises: [Defect].}

  LPProtocol* = ref object of RootObj
    codecs*: seq[string]
    handler*: LPProtoHandler ## this handler gets invoked by the protocol negotiator
    started*: bool
    maxIncomingStreams*: Opt[int]
    openedStreams*: CountTable[PeerId]

method init*(p: LPProtocol) {.base, gcsafe.} = discard
method start*(p: LPProtocol) {.async, base.} = p.started = true
method stop*(p: LPProtocol) {.async, base.} = p.started = false

proc handleIncoming*(protocol: LPProtocol, conn: Connection, proto: string) {.async.} =
  let maxIncomingStreams = protocol.maxIncomingStreams.get(DefaultMaxIncomingStreams)
  if protocol.openedStreams.getOrDefault(conn.peerId) >= maxIncomingStreams:
    debug "Max streams for protocol reached, blocking new stream",
      conn, proto, maxIncomingStreams
    await conn.close()
  protocol.openedStreams.inc(conn.peerId)
  defer: protocol.openedStreams.inc(conn.peerId, -1)
  await protocol.handler(conn, proto)

func codec*(p: LPProtocol): string =
  assert(p.codecs.len > 0, "Codecs sequence was empty!")
  p.codecs[0]

func `codec=`*(p: LPProtocol, codec: string) =
  # always insert as first codec
  # if we use this abstraction
  p.codecs.insert(codec, 0)

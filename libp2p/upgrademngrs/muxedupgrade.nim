# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/sequtils
import pkg/[chronos, chronicles, metrics]

import ../upgrademngrs/upgrade,
       ../muxers/muxer

export Upgrade

logScope:
  topics = "libp2p muxedupgrade"

type
  MuxedUpgrade* = ref object of Upgrade
    muxers*: seq[MuxerProvider]
    streamHandler*: StreamHandler

proc getMuxerByCodec(self: MuxedUpgrade, muxerName: string): MuxerProvider =
  for m in self.muxers:
    if muxerName == m.codec:
      return m

proc mux*(
  self: MuxedUpgrade,
  conn: Connection,
  direction: Direction): Future[Muxer] {.async, gcsafe.} =
  ## mux connection

  trace "Muxing connection", conn
  if self.muxers.len == 0:
    warn "no muxers registered, skipping upgrade flow", conn
    return

  let muxerName =
    if direction == Out: await self.ms.select(conn, self.muxers.mapIt(it.codec))
    else: await MultistreamSelect.handle(conn, self.muxers.mapIt(it.codec))

  if muxerName.len == 0 or muxerName == "na":
    debug "no muxer available, early exit", conn
    return

  trace "Found a muxer", conn, muxerName

  # create new muxer for connection
  let muxer = self.getMuxerByCodec(muxerName).newMuxer(conn, Opt.some(direction))

  # install stream handler
  muxer.streamHandler = self.streamHandler
  muxer.handler = muxer.handle()
  return muxer

method upgrade*(
  self: MuxedUpgrade,
  conn: Connection,
  direction: Direction,
  peerId: Opt[PeerId]): Future[Muxer] {.async.} =
  trace "Upgrading connection", conn, direction

  let sconn = await self.secure(conn, direction, peerId) # secure the connection
  if isNil(sconn):
    raise newException(UpgradeFailedError,
      "unable to secure connection, stopping upgrade")

  let muxer = await self.mux(sconn, direction) # mux it if possible
  if muxer == nil:
    raise newException(UpgradeFailedError,
      "a muxer is required for outgoing connections")

  when defined(libp2p_agents_metrics):
    conn.shortAgent = muxer.connection.shortAgent

  if sconn.closed():
    await sconn.close()
    raise newException(UpgradeFailedError,
      "Connection closed or missing peer info, stopping upgrade")

  trace "Upgraded connection", conn, sconn, direction
  return muxer

proc new*(
  T: type MuxedUpgrade,
  muxers: seq[MuxerProvider],
  secureManagers: openArray[Secure] = [],
  ms: MultistreamSelect): T =

  let upgrader = T(
    muxers: muxers,
    secureManagers: @secureManagers,
    ms: ms)

  upgrader.streamHandler = proc(conn: Connection)
    {.async, gcsafe, raises: [].} =
    trace "Starting stream handler", conn
    try:
      await upgrader.ms.handle(conn) # handle incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in stream handler", conn, msg = exc.msg
    finally:
      await conn.closeWithEOF()
    trace "Stream handler done", conn

  return upgrader

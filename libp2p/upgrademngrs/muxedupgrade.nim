# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import std/sequtils
import pkg/[chronos, chronicles, metrics]

import ../upgrademngrs/upgrade, ../muxers/muxer
import ../connmanager
import ../utility

export Upgrade

logScope:
  topics = "libp2p muxedupgrade"

type MuxedUpgrade* = ref object of Upgrade
  muxers*: seq[MuxerProvider]
  streamHandler*: StreamHandler
  connManager*: Opt[ConnManager]

func getMuxerByCodec(self: MuxedUpgrade, muxerName: string): Opt[MuxerProvider] =
  if muxerName.len == 0 or muxerName == "na":
    return Opt.none(MuxerProvider)
  for m in self.muxers:
    if muxerName == m.codec:
      return Opt.some(m)
  Opt.none(MuxerProvider)

proc mux(
    self: MuxedUpgrade, conn: Connection
): Future[Opt[Muxer]] {.
    async: (raises: [CancelledError, LPStreamError, MultiStreamError])
.} =
  ## mux connection
  trace "Muxing connection", conn
  if self.muxers.len == 0:
    warn "no muxers registered, skipping upgrade flow", conn
    return Opt.none(Muxer)

  let
    muxerName =
      case conn.dir
      of Direction.Out:
        await self.ms.select(conn, self.muxers.mapIt(it.codec))
      of Direction.In:
        await MultistreamSelect.handle(conn, self.muxers.mapIt(it.codec))
    muxerProvider = self.getMuxerByCodec(muxerName).valueOr:
      debug "no muxer available, early exit", conn, muxerName
      return Opt.none(Muxer)

  trace "Found a muxer", conn, muxerName

  # create new muxer for connection
  let muxer = muxerProvider.newMuxer(conn)

  # install stream handler
  muxer.streamHandler = self.streamHandler
  muxer.handler = muxer.handle()
  Opt.some(muxer)

method upgrade*(
    self: MuxedUpgrade, conn: Connection, peerId: Opt[PeerId]
): Future[Muxer] {.async: (raises: [CancelledError, LPError]).} =
  trace "Upgrading connection", conn, direction = conn.dir

  let sconn = await self.secure(conn, peerId) # secure the connection
  if sconn == nil:
    raise (ref UpgradeFailedError)(msg: "unable to secure connection, stopping upgrade")

  let muxer = (await self.mux(sconn)).valueOr:
    raise (ref UpgradeFailedError)(msg: "a muxer is required for outgoing connections")

  when defined(libp2p_agents_metrics):
    conn.shortAgent = muxer.connection.shortAgent

  if sconn.closed():
    await sconn.close()
    raise (ref UpgradeFailedError)(
      msg: "Connection closed or missing peer info, stopping upgrade"
    )

  trace "Upgraded connection", conn, sconn, direction = conn.dir
  muxer

proc new*(
    T: type MuxedUpgrade,
    muxers: seq[MuxerProvider],
    secureManagers: openArray[Secure] = [],
    ms: MultistreamSelect,
    connManager: Opt[ConnManager] = Opt.none(ConnManager),
): T =
  let upgrader =
    T(muxers: muxers, secureManagers: @secureManagers, ms: ms, connManager: connManager)

  upgrader.streamHandler = proc(conn: Connection) {.async: (raises: []).} =
    trace "Starting stream handler", conn
    try:
      upgrader.connManager.withValue(connManager):
        let ready = await connManager.waitForPeerReady(conn.peerId)
        if not ready:
          debug "Timed out waiting for peer ready before handling stream", conn
          return
      await upgrader.ms.handle(conn) # handle incoming connection
    except CancelledError as exc:
      return
    finally:
      await conn.closeWithEOF()
    trace "Stream handler done", conn

  return upgrader

proc new*(
    T: type MuxedUpgrade,
    muxers: seq[MuxerProvider],
    secureManagers: openArray[Secure] = [],
    ms: MultistreamSelect,
    connManager: ConnManager,
): T =
  T.new(muxers, secureManagers, ms, connManager.toOpt())

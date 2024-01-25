# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push gcsafe.}
{.push raises: [].}

import std/[sequtils, strutils]
import pkg/[chronos, chronicles, metrics]

import ../stream/connection,
       ../protocols/secure/secure,
       ../protocols/identify,
       ../muxers/muxer,
       ../multistream,
       ../connmanager,
       ../errors,
       ../utility

export connmanager, connection, identify, secure, multistream

declarePublicCounter(libp2p_failed_upgrades_incoming, "incoming connections failed upgrades")
declarePublicCounter(libp2p_failed_upgrades_outgoing, "outgoing connections failed upgrades")

logScope:
  topics = "libp2p upgrade"

type
  UpgradeFailedError* = object of LPError

  Upgrade* = ref object of RootObj
    ms*: MultistreamSelect
    secureManagers*: seq[Secure]

method upgrade*(
  self: Upgrade,
  conn: Connection,
  peerId: Opt[PeerId]): Future[Muxer] {.base.} =
  doAssert(false, "Not implemented!")

proc secure*(
  self: Upgrade,
  conn: Connection,
  peerId: Opt[PeerId]): Future[Connection] {.async.} =
  if self.secureManagers.len <= 0:
    raise newException(UpgradeFailedError, "No secure managers registered!")

  let codec =
    if conn.dir == Out: await self.ms.select(conn, self.secureManagers.mapIt(it.codec))
    else: await MultistreamSelect.handle(conn, self.secureManagers.mapIt(it.codec))
  if codec.len == 0:
    raise newException(UpgradeFailedError, "Unable to negotiate a secure channel!")

  trace "Securing connection", conn, codec
  let secureProtocol = self.secureManagers.filterIt(it.codec == codec)

  # ms.select should deal with the correctness of this
  # let's avoid duplicating checks but detect if it fails to do it properly
  doAssert(secureProtocol.len > 0)

  return await secureProtocol[0].secure(conn, peerId)

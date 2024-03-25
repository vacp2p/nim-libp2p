# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
##

{.push raises: [].}

import sequtils
import chronos, chronicles
import ../stream/connection,
       ../multiaddress,
       ../multicodec,
       ../muxers/muxer,
       ../upgrademngrs/upgrade,
       ../protocols/connectivity/autonat/core

export core.NetworkReachability

logScope:
  topics = "libp2p transport"

type
  TransportError* = object of LPError
  TransportInvalidAddrError* = object of TransportError
  TransportClosedError* = object of TransportError

  Transport* = ref object of RootObj
    addrs*: seq[MultiAddress]
    running*: bool
    upgrader*: Upgrade
    networkReachability*: NetworkReachability

proc newTransportClosedError*(parent: ref Exception = nil): ref LPError =
  newException(TransportClosedError,
    "Transport closed, no more connections!", parent)

method start*(
  self: Transport,
  addrs: seq[MultiAddress]) {.base, async.} =
  ## start the transport
  ##

  trace "starting transport on addrs", address = $addrs
  self.addrs = addrs
  self.running = true

method stop*(self: Transport) {.base, async.} =
  ## stop and cleanup the transport
  ## including all outstanding connections
  ##

  trace "stopping transport", address = $self.addrs
  self.running = false

method accept*(self: Transport): Future[Connection]
               {.base, gcsafe.} =
  ## accept incoming connections
  ##

  doAssert(false, "Not implemented!")

method dial*(
  self: Transport,
  hostname: string,
  address: MultiAddress,
  peerId: Opt[PeerId] = Opt.none(PeerId)): Future[Connection] {.base, gcsafe.} =
  ## dial a peer
  ##

  doAssert(false, "Not implemented!")

proc dial*(
  self: Transport,
  address: MultiAddress,
  peerId: Opt[PeerId] = Opt.none(PeerId)): Future[Connection] {.gcsafe.} =
  self.dial("", address)

method upgrade*(
    self: Transport,
    conn: Connection,
    peerId: Opt[PeerId]
): Future[Muxer] {.base, async: (raises: [
    CancelledError, LPError], raw: true).} =
  ## base upgrade method that the transport uses to perform
  ## transport specific upgrades
  ##
  self.upgrader.upgrade(conn, peerId)

method handles*(
    self: Transport,
    address: MultiAddress): bool {.base, gcsafe.} =
  ## check if transport supports the multiaddress
  ##
  # by default we skip circuit addresses to avoid
  # having to repeat the check in every transport
  let protocols = address.protocols.valueOr: return false
  protocols
    .filterIt(
      it == multiCodec("p2p-circuit")
    ).len == 0

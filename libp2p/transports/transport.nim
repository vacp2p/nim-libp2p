## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
##

{.push raises: [Defect].}

import sequtils
import chronos, chronicles
import ../stream/connection,
       ../multiaddress,
       ../multicodec,
       ../upgrademngrs/upgrade

logScope:
  topics = "libp2p transport"

type
  ListenErrorCallback* = proc (
      ma: MultiAddress,
      err: ref CatchableError): Future[ref TransportListenError]
      {.gcsafe, raises: [Defect].}
  TransportError* = object of LPError
  TransportInvalidAddrError* = object of TransportError
  TransportClosedError* = object of TransportError
  TransportListenError* = object of TransportError
    ma*: MultiAddress

  Transport* = ref object of RootObj
    addrs*: seq[MultiAddress]
    running*: bool
    upgrader*: Upgrade
    listenError*: ListenErrorCallback

proc newTransportClosedError*(parent: ref Exception = nil): ref LPError =
  newException(TransportClosedError,
    "Transport closed, no more connections!", parent)

proc newTransportListenError*(
    ma: MultiAddress,
    parent: ref Exception = nil): ref TransportListenError =

  return (ref TransportListenError)(msg: "Transport failed to start", parent: parent, ma: ma)

const ListenErrorDefault* =
  proc(
      ma: MultiAddress,
      err: ref CatchableError): Future[ref TransportListenError] {.async.} =

    return newTransportListenError(ma, err)

method start*(
  self: Transport,
  addrs: seq[MultiAddress]) {.base, async, raises: [TransportListenError].} =
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
  address: MultiAddress): Future[Connection] {.base, gcsafe.} =
  ## dial a peer
  ##

  doAssert(false, "Not implemented!")

proc dial*(
  self: Transport,
  address: MultiAddress): Future[Connection] {.gcsafe.} =
  self.dial("", address)

method upgradeIncoming*(
  self: Transport,
  conn: Connection): Future[void] {.base, gcsafe.} =
  ## base upgrade method that the transport uses to perform
  ## transport specific upgrades
  ##

  self.upgrader.upgradeIncoming(conn)

method upgradeOutgoing*(
  self: Transport,
  conn: Connection): Future[Connection] {.base, gcsafe.} =
  ## base upgrade method that the transport uses to perform
  ## transport specific upgrades
  ##

  self.upgrader.upgradeOutgoing(conn)

method handles*(
  self: Transport,
  address: MultiAddress): bool {.base, gcsafe.} =
  ## check if transport supports the multiaddress
  ##

  # by default we skip circuit addresses to avoid
  # having to repeat the check in every transport
  if address.protocols.isOk:
    return address.protocols
    .get()
    .filterIt(
      it == multiCodec("p2p-circuit")
    ).len == 0

method `==`*(
    a: Transport, b: Transport): bool {.base, gcsafe.} =

  return
    a.addrs == b.addrs and
    a.running == b.running and
    a.listenError == b.listenError

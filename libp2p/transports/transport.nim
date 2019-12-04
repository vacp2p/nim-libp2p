## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils
import chronos, chronicles
import ../connection,
       ../multiaddress,
       ../multicodec

type
  ConnHandler* = proc (conn: Connection): Future[void] {.gcsafe.}

  ConnHolder* = object
    connection*: Connection
    connFuture*: Future[void]

  Transport* = ref object of RootObj
    ma*: Multiaddress
    connections*: seq[ConnHolder]
    handler*: ConnHandler
    multicodec*: MultiCodec

method init*(t: Transport) {.base, gcsafe.} =
  ## perform protocol initialization
  discard

proc newTransport*(t: typedesc[Transport]): t {.gcsafe.} =
  new result
  result.init()

method close*(t: Transport) {.base, async, gcsafe.} =
  ## stop and cleanup the transport
  ## including all outstanding connections
  await allFutures(t.connections.mapIt(it.connection.close()))

method listen*(t: Transport,
               ma: MultiAddress,
               handler: ConnHandler):
               Future[Future[void]] {.base, async, gcsafe.} =
  ## listen for incoming connections
  t.ma = ma
  t.handler = handler
  trace "starting node", address = $ma

method dial*(t: Transport,
             address: MultiAddress):
             Future[Connection] {.base, async, gcsafe.} =
  ## dial a peer
  discard

method upgrade*(t: Transport) {.base, async, gcsafe.} =
  ## base upgrade method that the transport uses to perform
  ## transport specific upgrades
  discard

method handles*(t: Transport, address: MultiAddress): bool {.base, gcsafe.} =
  ## check if transport supportes the multiaddress

  # by default we skip circuit addresses to avoid 
  # having to repeat the check in every transport
  address.protocols.filterIt( it == multiCodec("p2p-circuit") ).len == 0

method localAddress*(t: Transport): MultiAddress {.base, gcsafe.} =
  ## get the local address of the transport in case started with 0.0.0.0:0
  discard

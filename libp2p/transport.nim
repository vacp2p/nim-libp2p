## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import peerinfo, connection, multiaddress, multicodec

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
  for c in t.connections:
    await c.connection.close()

method listen*(t: Transport,
               ma: MultiAddress,
               handler: ConnHandler) {.base, async, gcsafe.} =
  ## listen for incoming connections
  t.ma = ma
  t.handler = handler

method dial*(t: Transport,
             address: MultiAddress): 
             Future[Connection] {.base, async, gcsafe.} =
  ## dial a peer
  discard

method handles*(t: Transport, address: MultiAddress): bool {.base, gcsafe.} =
  ## check if transport supportes the multiaddress
  # TODO: this should implement generic logic that would use the multicodec 
  # declared in the multicodec field and set by each individual transport
  discard

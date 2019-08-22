## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import peerinfo, connection, multiaddress, multicodec, readerwriter

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

method init*(t: Transport) {.base, error: "not implemented".} = 
  ## perform protocol initialization
  discard

proc newTransport*(t: typedesc[Transport]): t = 
  new result
  result.init()

method close*(t: Transport) {.base, async.} =
  ## stop and cleanup the transport
  ## including all outstanding connections
  for c in t.connections:
    await c.connection.close()

method listen*(t: Transport, ma: MultiAddress, handler: ConnHandler) {.base, async.} =
  ## listen for incoming connections
  t.ma = ma
  t.handler = handler

method dial*(t: Transport, address: MultiAddress): Future[Connection] {.base, async, error: "not implemented".} = 
  ## dial a peer
  discard

method supports(t: Transport, address: MultiAddress): bool {.base, error: "not implemented".} = 
  ## check if transport supportes the multiaddress
  # TODO: this should implement generic logic that would use the multicodec 
  # declared in the multicodec field and set by each individual transport
  discard

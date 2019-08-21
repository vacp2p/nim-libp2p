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

method init*(t: Transport) {.base.} = 
  ## perform protocol initialization
  discard

proc newTransport*(t: typedesc[Transport], 
          ma: MultiAddress, 
          handler: ConnHandler): t = 
  new result
  result.ma = ma
  result.handler = handler
  result.init()

method close*(t: Transport) {.base, async.} =
  ## start the transport
  discard

method listen*(t: Transport) {.base, async.} =
  ## stop the transport
  discard

method dial*(t: Transport, address: MultiAddress): Future[Connection] {.base, async.} = 
  ## dial a peer
  discard

method supports(t: Transport, address: MultiAddress): bool {.base.} = 
  ## check if transport supportes the multiaddress
  # TODO: this should implement generic logic that would use the multicodec 
  # declared in the multicodec field and set by each individual transport
  result = true

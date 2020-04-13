## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import stream,
       ../peerinfo,
       ../multiaddress

type
  Connection*[T] = ref object of Stream[T]
    stream*: Stream[T]
    peerInfo*: PeerInfo
    observedAddr*: MultiAddress

proc init*[T](c: type[Connection[T]], stream: Stream[T]): c =
  Connection(stream: stream)

proc source*[T](c: Connection): Source[T] =
  c.stream.source()

proc sink*[T](c: Connection): Sink[T] =
  c.stream.sink()

proc getObservedAddrs*(c: Connection): Future[MultiAddress] =
  ## get resolved multiaddresses for the connection
  c.observedAddrs

proc `$`*(c: Connection): string =
  if not isNil(c.peerInfo):
    result = $(c.peerInfo)

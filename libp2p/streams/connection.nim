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
  Connection* = ref object of Stream
    peerInfo*: PeerInfo
    observedAddr*: MultiAddress
    stream*: Stream

proc init*(C: type[Connection],
           stream: Stream,
           peerInfo: PeerInfo = nil): C =
  Connection(stream: stream, peerInfo: peerInfo)

proc source*(s: Connection): Source[seq[byte]] =
  source(s.stream)

proc sink*(s: Connection): Sink[seq[byte]] =
  sink(s.stream)

proc close*(s: Connection) {.async.} =
  result = close(s.stream)

proc closed*(s: Connection): bool =
  s.stream.closed

proc getObservedAddrs*(c: Connection): Future[MultiAddress] {.async.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddr

proc `$`*(c: Connection): string =
  if not isNil(c.peerInfo):
    result = $(c.peerInfo)

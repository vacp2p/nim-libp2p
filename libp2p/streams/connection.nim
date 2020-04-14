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
  Connection* = ref object of Stream[seq[byte]]
    peerInfo*: PeerInfo
    observedAddr*: MultiAddress
    stream*: Stream[seq[byte]]

proc init*[T](C: type[Connection],
              stream: T,
              peerInfo: PeerInfo = nil): C =
  Connection(stream: stream, peerInfo: peerInfo)

proc source*(s: Connection): Source[seq[byte]] =
  result = s.stream.source()

proc sink*(s: Connection): Sink[seq[byte]] =
  static:
    echo "type of stream ", typeof s.stream
  result = s.stream.sink()

proc close*(s: Connection) {.async.} =
  result = s.stream.close()

proc closed*(s: Connection): bool =
  s.stream.isClosed

proc getObservedAddrs*(c: Connection): Future[MultiAddress] {.async.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddr

proc `$`*(c: Connection): string =
  if not isNil(c.peerInfo):
    result = $(c.peerInfo)

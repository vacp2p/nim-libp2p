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

proc connSource*(s: Stream[seq[byte]]): Source[seq[byte]] {.gcsafe.} =
  if not isNil(s.sourceImpl):
    var c = Connection(s)
    return c.stream.sourceImpl(c.stream)

proc connSink*(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
  if not isNil(s.sinkImpl):
    var c = Connection(s)
    return c.stream.sinkImpl(c.stream)

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

proc init*[T](C: type[Connection],
           stream: T,
           peerInfo: PeerInfo = nil): C =

  Connection(stream: stream,
             sourceImpl: connSource,
             sinkImpl: connSink,
             peerInfo: peerInfo,
             name: "Connection")

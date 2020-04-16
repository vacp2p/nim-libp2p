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

  Connection(stream: stream,
             sourceImpl: stream.sourceImpl,
             sinkImpl: stream.sinkImpl,
             peerInfo: peerInfo,
             name: "Connection")

proc source*(s: Connection): Source[seq[byte]] =
  if not isNil(s.sourceImpl):
    return s.sourceImpl(s.stream)

proc sink*(s: Connection): Sink[seq[byte]] =
  if not isNil(s.sinkImpl):
    return s.sinkImpl(s.stream)

proc close*(s: Connection) {.async.} =
  result = close(s.stream)

proc closed*(s: Connection): bool =
  s.stream.closed

proc duplex*(s: Connection): (Source[seq[byte]], Sink[seq[byte]]) =
  var source = if isNil(s.sourceImpl): nil else: s.sourceImpl(s.stream)
  var sink = if isNil(s.sourceImpl): nil else: s.sinkImpl(s.stream)
  (source, sink)

proc getObservedAddrs*(c: Connection): Future[MultiAddress] {.async.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddr

proc `$`*(c: Connection): string =
  if not isNil(c.peerInfo):
    result = $(c.peerInfo)

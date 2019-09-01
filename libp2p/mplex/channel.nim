## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../connection, ../stream
import mplex

type
  Channel = ref object of LPStream
    id*: int
    initiator*: bool
    reset*: bool
    closedLocal*: bool
    closedRemote*: bool
    buffer*: seq[byte]

proc newChannel*(mplex: Mplex, id: int, initiator: bool): Channel = 
  new result
  result.id = id
  result.initiator = initiator

proc closed*(s: Channel): bool = s.closedLocal and s.closedRemote
proc close*(s: Channel) = discard

method read*(s: Channel, n = -1): Future[seq[byte]] {.async, gcsafe.} =
  discard

method readExactly*(s: Channel, pbytes: pointer, nbytes: int): Future[void] {.async, gcsafe.} =
  discard

method readLine*(s: Channel, limit = 0, sep = "\r\n"): Future[string] {.async, gcsafe.} =
  discard

method readOnce*(s: Channel, pbytes: pointer, nbytes: int): Future[int] {.async, gcsafe.} =
  discard

method readUntil*(s: Channel,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]): Future[int] {.async, gcsafe.} =
  discard

method write*(s: Channel, pbytes: pointer, nbytes: int) {.async, gcsafe.} =
  discard

method write*(s: Channel, msg: string, msglen = -1) {.async, gcsafe.} =
  discard

method write*(s: Channel, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  discard

method close*(s: Channel) {.async, gcsafe.} =
  discard

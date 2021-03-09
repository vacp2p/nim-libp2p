## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import peerid,
       stream/connection

type
  Dial* = ref object of RootObj

method connect*(
  self: Dial,
  peerId: PeerID,
  addrs: seq[MultiAddress]) {.async, base.} =
  ## attempt to create establish a connection
  ## with a remote peer
  ##

  doAssert(false, "Not implemented!")

method dial*(
  self: Dial,
  peerId: PeerID,
  protos: seq[string]): Future[Connection] {.async, base.} =
  doAssert(false, "Not implemented!")

method dial*(
  self: Dial,
  peerId: PeerID,
  addrs: seq[MultiAddress],
  protos: seq[string]): Future[Connection] {.async, base.} =
  doAssert(false, "Not implemented!")

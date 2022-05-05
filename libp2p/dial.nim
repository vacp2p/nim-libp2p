## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import chronos
import peerid,
       stream/connection

type
  Dial* = ref object of RootObj

method connect*(
  self: Dial,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  forceDial = false) {.async, base.} =
  ## connect remote peer without negotiating
  ## a protocol
  ##

  doAssert(false, "Not implemented!")

method dial*(
  self: Dial,
  peerId: PeerId,
  protos: seq[string],
  ): Future[Connection] {.async, base.} =
  ## create a protocol stream over an
  ## existing connection
  ##

  doAssert(false, "Not implemented!")

method dial*(
  self: Dial,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  protos: seq[string],
  forceDial = false): Future[Connection] {.async, base.} =
  ## create a protocol stream and establish
  ## a connection if one doesn't exist already
  ##

  doAssert(false, "Not implemented!")

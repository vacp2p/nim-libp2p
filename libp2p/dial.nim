# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos
import stew/results
import peerid, stream/connection, transports/transport

export results

type Dial* = ref object of RootObj

method connect*(
    self: Dial,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
) {.async, base.} =
  ## connect remote peer without negotiating
  ## a protocol
  ##

  doAssert(false, "Not implemented!")

method connect*(
    self: Dial, address: MultiAddress, allowUnknownPeerId = false
): Future[PeerId] {.async, base.} =
  ## Connects to a peer and retrieve its PeerId

  doAssert(false, "Not implemented!")

method dial*(
    self: Dial, peerId: PeerId, protos: seq[string]
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
    forceDial = false,
): Future[Connection] {.async, base.} =
  ## create a protocol stream and establish
  ## a connection if one doesn't exist already
  ##

  doAssert(false, "Not implemented!")

method addTransport*(self: Dial, transport: Transport) {.base.} =
  doAssert(false, "Not implemented!")

method tryDial*(
    self: Dial, peerId: PeerId, addrs: seq[MultiAddress]
): Future[Opt[MultiAddress]] {.async, base.} =
  doAssert(false, "Not implemented!")

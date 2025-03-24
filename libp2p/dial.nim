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

type
  Dial* = ref object of RootObj
  DialFailedError* = object of LPError

method connect*(
    self: Dial,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
) {.base, async: (raises: [DialFailedError, CancelledError]).} =
  ## connect remote peer without negotiating
  ## a protocol
  ##

  doAssert(false, "[Dial.connect] abstract method not implemented!")

method connect*(
    self: Dial, address: MultiAddress, allowUnknownPeerId = false
): Future[PeerId] {.base, async: (raises: [DialFailedError, CancelledError]).} =
  ## Connects to a peer and retrieve its PeerId

  doAssert(false, "[Dial.connect] abstract method not implemented!")

method dial*(
    self: Dial, peerId: PeerId, protos: seq[string]
): Future[Connection] {.base, async: (raises: [DialFailedError, CancelledError]).} =
  ## create a protocol stream over an
  ## existing connection
  ##

  doAssert(false, "[Dial.dial] abstract method not implemented!")

method dial*(
    self: Dial,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    protos: seq[string],
    forceDial = false,
): Future[Connection] {.base, async: (raises: [DialFailedError, CancelledError]).} =
  ## create a protocol stream and establish
  ## a connection if one doesn't exist already
  ##

  doAssert(false, "[Dial.dial] abstract method not implemented!")

method addTransport*(self: Dial, transport: Transport) {.base.} =
  doAssert(false, "[Dial.addTransport] abstract method not implemented!")

method tryDial*(
    self: Dial, peerId: PeerId, addrs: seq[MultiAddress]
): Future[Opt[MultiAddress]] {.
    base, async: (raises: [DialFailedError, CancelledError])
.} =
  doAssert(false, "[Dial.tryDial] abstract method not implemented!")

# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import tables
import chronos,
       chronicles
import ../protocol,
       ../../peerid,
       ../../multiaddress,
       ../../errors

type
  DiscoveryError* = object of LPError

  DiscoveryFilter* = Table[string, string]
  DiscoveryResult* = object
    id*: PeerId
    ma*: MultiAddress
    filter*: DiscoveryFilter

  PeerFoundCallback* = proc(filter: DiscoveryResult)

  DiscoveryInterface* = ref object of RootObj
    onPeerFound: PeerFoundCallback

method request(self: DiscoveryInterface, filter: DiscoveryFilter) {.async, base.} =
  doAssert(false, "Not implemented!")

method advertise(self: DiscoveryInterface) {.async, base.} =
  doAssert(false, "Not implemented!")

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

import chronos
import ./discoveryinterface,
       ../protocols/rendezvous

type
  RendezVousInterface = ref object of DiscoveryInterface
    rdv: RendezVous

method request(self: RendezVousInterface, filter: DiscoveryFilter) {.async.} =
  doAssert(false, "Not implemented!")

method advertise(self: RendezVousInterface) {.async.} =
  doAssert(false, "Not implemented!")

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

{.push raises: [].}

import chronos
import
  ../../libp2p/[protocols/connectivity/autonat/client, peerid, multiaddress, switch]
from ../../libp2p/protocols/connectivity/autonat/types import
  NetworkReachability, AutonatUnreachableError, AutonatError

type
  AutonatClientStub* = ref object of AutonatClient
    answer*: Answer
    dials: int
    expectedDials: int
    finished*: Future[void]

  Answer* = NetworkReachability

proc new*(T: typedesc[AutonatClientStub], expectedDials: int): T =
  return T(dials: 0, expectedDials: expectedDials, finished: newFuture[void]())

method dialMe*(
    self: AutonatClientStub,
    switch: Switch,
    pid: PeerId,
    addrs: seq[MultiAddress] = newSeq[MultiAddress](),
): Future[MultiAddress] {.
    async: (raises: [AutonatError, AutonatUnreachableError, CancelledError])
.} =
  self.dials += 1

  if self.dials == self.expectedDials:
    self.finished.complete()
  case self.answer
  of NetworkReachability.Reachable:
    return MultiAddress.init("/ip4/0.0.0.0/tcp/0").get()
  of NetworkReachability.NotReachable:
    raise newException(AutonatUnreachableError, "")
  of NetworkReachability.Unknown:
    raise newException(AutonatError, "")

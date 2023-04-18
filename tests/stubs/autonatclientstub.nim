# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos
import ../../libp2p/[protocols/connectivity/autonat/client,
                     peerid,
                     multiaddress,
                     switch]
from ../../libp2p/protocols/connectivity/autonat/core import NetworkReachability, AutonatUnreachableError, AutonatError

type
  AutonatClientStub* = ref object of AutonatClient
    answer*: Answer
    dials: int
    expectedDials: int
    finished*: Future[void]

  Answer* = enum
    Reachable,
    NotReachable,
    Unknown

proc new*(T: typedesc[AutonatClientStub], expectedDials: int): T =
  return T(dials: 0, expectedDials: expectedDials, finished: newFuture[void]())

method dialMe*(
  self: AutonatClientStub,
  switch: Switch,
  pid: PeerId,
  addrs: seq[MultiAddress] = newSeq[MultiAddress]()):
    Future[MultiAddress] {.async.} =

    self.dials += 1

    if self.dials == self.expectedDials:
      self.finished.complete()
    case self.answer:
      of Reachable:
        return MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      of NotReachable:
        raise newException(AutonatUnreachableError, "")
      of Unknown:
        raise newException(AutonatError, "")

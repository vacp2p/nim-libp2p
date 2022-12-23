{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos
import ../../libp2p/protocols/connectivity/autonat
import ../../libp2p/peerid
import ../../libp2p/multiaddress

type
  AutonatStub* = ref object of Autonat
    answer*: Answer
    dials: int
    expectedDials: int
    finished*: Future[void]

  Answer* = enum
    Reachable,
    NotReachable,
    Unknown

proc new*(T: typedesc[AutonatStub], expectedDials: int): T =
  return T(dials: 0, expectedDials: expectedDials, finished: newFuture[void]())

method dialMe*(
  self: AutonatStub,
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

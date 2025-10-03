import hashes, chronos, results, chronicles
import ../../stream/connection
import ./[serialization]
from fragmentation import DataSize

type MixReplyDialer* = proc(surbs: seq[SURB], msg: seq[byte]): Future[void] {.
  async: (raises: [CancelledError, LPStreamError])
.}

type MixReplyConnection* = ref object of Connection
  surbs: seq[SURB]
  mixReplyDialer: MixReplyDialer

method readExactly*(
    self: MixReplyConnection, pbytes: pointer, nbytes: int
): Future[void] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  raise newException(LPStreamError, "MixReplyConnection does not allow reading")

method write*(
    self: MixReplyConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  if msg.len() > DataSize:
    raise newException(LPStreamError, "exceeds max msg size of " & $DataSize & " bytes")
  await self.mixReplyDialer(self.surbs, msg)

proc shortLog*(self: MixReplyConnection): string {.raises: [].} =
  "[MixReplyConnection]"

chronicles.formatIt(MixReplyConnection):
  shortLog(it)

method initStream*(self: MixReplyConnection) =
  discard

method closeImpl*(self: MixReplyConnection): Future[void] {.async: (raises: []).} =
  discard

func hash*(self: MixReplyConnection): Hash =
  hash($self.surbs)

proc new*(
    T: typedesc[MixReplyConnection], surbs: seq[SURB], mixReplyDialer: MixReplyDialer
): T =
  T(surbs: surbs, mixReplyDialer: mixReplyDialer)

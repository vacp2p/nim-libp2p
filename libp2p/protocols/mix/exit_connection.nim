import hashes, chronos, chronicles
import ../../stream/connection
from fragmentation import DataSize

type MixExitConnection* = ref object of Connection
  message: seq[byte]
  response: seq[byte]

method readOnce*(
    self: MixExitConnection, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  if self.message.len == 0:
    return 0 # Nothing else to read.
  if self.message.len < nbytes:
    raise newException(
      LPStreamError, "Not enough data in to read exactly " & $nbytes & " bytes."
    )
  copyMem(pbytes, addr self.message[0], nbytes)
  self.message = self.message[nbytes ..^ 1]
  nbytes

method write*(
    self: MixExitConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  if msg.len() > DataSize:
    raise newException(LPStreamError, "exceeds max msg size of " & $DataSize & " bytes")
  self.response.add(msg)

func shortLog*(self: MixExitConnection): string {.raises: [].} =
  "MixExitConnection"

chronicles.formatIt(MixExitConnection):
  shortLog(it)

method initStream*(self: MixExitConnection) =
  discard

method closeImpl*(self: MixExitConnection): Future[void] {.async: (raises: []).} =
  discard

func hash*(self: MixExitConnection): Hash =
  discard

proc getResponse*(self: MixExitConnection): seq[byte] =
  let r = self.response
  self.response = @[]
  return r

proc new*(T: typedesc[MixExitConnection], message: seq[byte]): T =
  T(message: message)

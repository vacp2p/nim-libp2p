import hashes, chronos, results, chronicles
import ../../stream/connection
import ../../varint
import ../../utils/sequninit
import ./mix_protocol
from fragmentation import DataSize

const DefaultSurbs = uint8(4)

type MixDialer* = proc(
  msg: seq[byte], codec: string, destination: MixDestination
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).}

type MixParameters* = object
  expectReply*: Opt[bool]
  numSurbs*: Opt[uint8]

type MixEntryConnection* = ref object of Connection
  destination: MixDestination
  codec: string
  mixDialer: MixDialer
  params: MixParameters
  incoming: AsyncQueue[seq[byte]]
  incomingFut: Future[void]
  replyReceivedFut: Future[void]
  cached: seq[byte]

func shortLog*(conn: MixEntryConnection): string =
  if conn == nil:
    "MixEntryConnection(nil)"
  else:
    "MixEntryConnection(" & $conn.destination & ")"

chronicles.formatIt(MixEntryConnection):
  shortLog(it)

method readOnce*(
    s: MixEntryConnection, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  if s.isEof:
    raise newLPStreamEOFError()

  try:
    await s.replyReceivedFut
    if s.cached.len == 0:
      s.isEof = true
      raise newLPStreamEOFError()
  except CancelledError as exc:
    raise exc
  except LPStreamEOFError as exc:
    raise exc
  except CatchableError as exc:
    raise (ref LPStreamError)(msg: "error in readOnce: " & exc.msg, parent: exc)

  let toRead = min(nbytes, s.cached.len)
  copyMem(pbytes, addr s.cached[0], toRead)
  s.cached = s.cached[toRead ..^ 1]
  return toRead

method write*(
    self: MixEntryConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  if msg.len() > DataSize:
    raise newException(LPStreamError, "exceeds max msg size of " & $DataSize & " bytes")
  await self.mixDialer(msg, self.codec, self.destination)

proc shortLog*(self: MixEntryConnection): string {.raises: [].} =
  "[MixEntryConnection] Destination: " & $self.destination

method closeImpl*(self: MixEntryConnection): Future[void] {.async: (raises: []).} =
  if not self.incomingFut.isNil:
    self.incomingFut.cancelSoon()

func hash*(self: MixEntryConnection): Hash =
  hash($self.destination)

proc new*(
    T: typedesc[MixEntryConnection],
    srcMix: MixProtocol,
    destination: MixDestination,
    codec: string,
    params: MixParameters,
): T {.raises: [].} =
  let expectReply = params.expectReply.get(false)
  let numSurbs =
    if expectReply:
      params.numSurbs.get(DefaultSurbs)
    else:
      0

  var instance = T()
  instance.destination = destination
  instance.codec = codec

  if expectReply:
    instance.incoming = newAsyncQueue[seq[byte]]()
    instance.replyReceivedFut = newFuture[void]()
    let checkForIncoming = proc(): Future[void] {.async: (raises: [CancelledError]).} =
      instance.cached = await instance.incoming.get()
      instance.replyReceivedFut.complete()
    instance.incomingFut = checkForIncoming()

  instance.mixDialer = proc(
      msg: seq[byte], codec: string, dest: MixDestination
  ): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
    let sendRes = await srcMix.anonymizeLocalProtocolSend(
      instance.incoming, msg, codec, dest, numSurbs
    )
    if sendRes.isErr:
      raise newException(LPStreamError, sendRes.error)

  instance

proc toConnection*(
    srcMix: MixProtocol,
    destination: MixDestination,
    codec: string,
    params: MixParameters = MixParameters(),
): Result[Connection, string] {.gcsafe, raises: [].} =
  ## Create a stream to send and optionally receive responses.
  ## Under the hood it will wrap the message in a sphinx packet
  ## and send it via a random mix path.
  if not srcMix.hasDestReadBehavior(codec):
    if params.expectReply.get(false):
      return err("no destination read behavior for codec")
    else:
      warn "no destination read behavior for codec", codec

  ok(MixEntryConnection.new(srcMix, destination, codec, params))

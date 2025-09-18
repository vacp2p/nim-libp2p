import hashes, chronos, stew/byteutils, results, chronicles
import ../../stream/connection
import ../../varint
import ../../utils/sequninit
import ./mix_protocol
from fragmentation import DataSize

type MixDialer* = proc(
  msg: seq[byte], codec: string, destination: MixDestination
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).}

type MixEntryConnection* = ref object of Connection
  destination: MixDestination
  codec: string
  mixDialer: MixDialer

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
  # TODO: implement
  raise newLPStreamEOFError()

method readExactly*(
    s: MixEntryConnection, pbytes: pointer, nbytes: int
): Future[void] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  # TODO: implement
  raise newLPStreamEOFError()

method readLine*(
    s: MixEntryConnection, limit = 0, sep = "\r\n"
): Future[string] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  # TODO: implement
  raise newLPStreamEOFError()

method readVarint*(
    conn: MixEntryConnection
): Future[uint64] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  # TODO: implement
  raise newLPStreamEOFError()

method readLp*(
    s: MixEntryConnection, maxSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  # TODO: implement
  raise newLPStreamEOFError()

method write*(
    self: MixEntryConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true), public.} =
  self.mixDialer(msg, self.codec, self.destination)

proc write*(
    self: MixEntryConnection, msg: string
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true), public.} =
  self.write(msg.toBytes())

method writeLp*(
    self: MixEntryConnection, msg: openArray[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true), public.} =
  if msg.len() > DataSize:
    let fut = newFuture[void]()
    fut.fail(
      newException(LPStreamError, "exceeds max msg size of " & $DataSize & " bytes")
    )
    return fut

  var
    vbytes: seq[byte] = @[]
    value = msg.len().uint64

  while value >= 128:
    vbytes.add(byte((value and 127) or 128))
    value = value shr 7
  vbytes.add(byte(value))

  var buf = newSeqUninit[byte](msg.len() + vbytes.len)
  buf[0 ..< vbytes.len] = vbytes.toOpenArray(0, vbytes.len - 1)
  buf[vbytes.len ..< buf.len] = msg

  self.mixDialer(@buf, self.codec, self.destination)

method writeLp*(
    self: MixEntryConnection, msg: string
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true), public.} =
  self.writeLp(msg.toOpenArrayByte(0, msg.high))

proc shortLog*(self: MixEntryConnection): string {.raises: [].} =
  "[MixEntryConnection] Destination: " & $self.destination

method closeImpl*(
    self: MixEntryConnection
): Future[void] {.async: (raises: [], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  return fut

func hash*(self: MixEntryConnection): Hash =
  hash($self.destination)

when defined(libp2p_agents_metrics):
  proc setShortAgent*(self: MixEntryConnection, shortAgent: string) =
    discard

proc new*(
    T: typedesc[MixEntryConnection],
    srcMix: MixProtocol,
    destination: MixDestination,
    codec: string,
): T {.raises: [].} =
  var instance = T()
  instance.destination = destination
  instance.codec = codec
  instance.mixDialer = proc(
      msg: seq[byte], codec: string, dest: MixDestination
  ): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
    try:
      await srcMix.anonymizeLocalProtocolSend(
        nil, msg, codec, dest, 0 # TODO: set incoming queue for replies and surbs
      )
    except CatchableError as e:
      error "Error during execution of anonymizeLocalProtocolSend: ", err = e.msg
    return

  when defined(libp2p_agents_metrics):
    instance.shortAgent = connection.shortAgent

  instance

proc toConnection*(
    srcMix: MixProtocol, destination: MixDestination, codec: string
): Result[Connection, string] {.gcsafe, raises: [].} =
  ## Create a stream to send and optionally receive responses.
  ## Under the hood it will wrap the message in a sphinx packet
  ## and send it via a random mix path.
  ok(MixEntryConnection.new(srcMix, destination, codec))

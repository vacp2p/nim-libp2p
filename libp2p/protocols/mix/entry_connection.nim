import hashes, chronos, stew/byteutils, results, chronicles
import ../../stream/connection
import ../../varint
import ../../utils/sequninit
import ./mix_protocol
from fragmentation import DataSize

const DefaultSurbs = uint8(4) # Default number of SURBs to send

type MixDialer* = proc(
  msg: seq[byte], codec: string, destination: MixDestination
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).}

## Holds configuration parameters used in mix protocol operations.  
type MixParameters* = object
  expectReply*: Opt[bool]
  numSurbs*: Opt[uint8]

type MixEntryConnection* = ref object of Connection
  destination: MixDestination
  codec: string
  mixDialer: MixDialer
  params: Opt[MixParameters]

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
    s.isEof = true
    if s.cached.len == 0:
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

method readExactly*(
    s: MixEntryConnection, pbytes: pointer, nbytes: int
): Future[void] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  ## Waits for `nbytes` to be available, then read
  ## them and return them
  if s.atEof:
    var ch: char
    discard await s.readOnce(addr ch, 1)
    raise newLPStreamEOFError()

  if nbytes == 0:
    return

  logScope:
    s
    nbytes = nbytes
    objName = s.objName

  var pbuffer = cast[ptr UncheckedArray[byte]](pbytes)
  var read = 0
  while read < nbytes and not (s.atEof()):
    read += await s.readOnce(addr pbuffer[read], nbytes - read)

  if read == 0:
    doAssert s.atEof()
    trace "couldn't read all bytes, stream EOF", s, nbytes, read
    # Re-readOnce to raise a more specific error than EOF
    # Raise EOF if it doesn't raise anything(shouldn't happen)
    discard await s.readOnce(addr pbuffer[read], nbytes - read)

    raise newLPStreamEOFError()

  if read < nbytes:
    trace "couldn't read all bytes, incomplete data", s, nbytes, read
    raise newLPStreamIncompleteError()

method readLine*(
    s: MixEntryConnection, limit = 0, sep = "\r\n"
): Future[string] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  ## Reads up to `limit` bytes are read, or a `sep` is found
  # TODO replace with something that exploits buffering better
  var lim = if limit <= 0: -1 else: limit
  var state = 0

  while true:
    var ch: char
    await readExactly(s, addr ch, 1)

    if sep[state] == ch:
      inc(state)
      if state == len(sep):
        break
    else:
      state = 0
      if limit > 0:
        let missing = min(state, lim - len(result) - 1)
        result.add(sep[0 ..< missing])
      else:
        result.add(sep[0 ..< state])

      result.add(ch)
      if len(result) == lim:
        break

method readVarint*(
    conn: MixEntryConnection
): Future[uint64] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  var buffer: array[10, byte]

  for i in 0 ..< len(buffer):
    await conn.readExactly(addr buffer[i], 1)

    var
      varint: uint64
      length: int
    let res = PB.getUVarint(buffer.toOpenArray(0, i), length, varint)
    if res.isOk():
      return varint
    if res.error() != VarintError.Incomplete:
      break
  if true: # can't end with a raise apparently
    raise (ref InvalidVarintError)(msg: "Cannot parse varint")

method readLp*(
    s: MixEntryConnection, maxSize: int
): Future[seq[byte]] {.async: (raises: [CancelledError, LPStreamError]), public.} =
  ## read length prefixed msg, with the length encoded as a varint
  let
    length = await s.readVarint()
    maxLen = uint64(if maxSize < 0: int.high else: maxSize)

  if length > maxLen:
    raise (ref MaxSizeError)(msg: "Message exceeds maximum length")

  if length == 0:
    return

  var res = newSeqUninitialized[byte](length)
  await s.readExactly(addr res[0], res.len)
  res

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

  ## Write `msg` with a varint-encoded length prefix
  let vbytes = PB.toBytes(msg.len().uint64)
  var buf = newSeqUninit[byte](msg.len() + vbytes.len)
  buf[0 ..< vbytes.len] = vbytes.toOpenArray()
  buf[vbytes.len ..< buf.len] = msg

  self.write(buf)

method writeLp*(
    self: MixEntryConnection, msg: string
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true), public.} =
  self.writeLp(msg.toOpenArrayByte(0, msg.high))

proc shortLog*(self: MixEntryConnection): string {.raises: [].} =
  "[MixEntryConnection] Destination: " & $self.destination

method closeImpl*(
    self: MixEntryConnection
): Future[void] {.async: (raises: [], raw: true).} =
  self.incomingFut.cancelSoon()
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
    params: Opt[MixParameters],
): T {.raises: [].} =
  let params = params.get(MixParameters())
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
    await srcMix.anonymizeLocalProtocolSend(
      instance.incoming, msg, codec, dest, numSurbs
    )

  when defined(libp2p_agents_metrics):
    instance.shortAgent = connection.shortAgent

  instance

proc toConnection*(
    srcMix: MixProtocol,
    destination: MixDestination,
    codec: string,
    params: Opt[MixParameters] = Opt.none(MixParameters),
): Result[Connection, string] {.gcsafe, raises: [].} =
  ## Create a stream to send and optionally receive responses.
  ## Under the hood it will wrap the message in a sphinx packet
  ## and send it via a random mix path.
  if not srcMix.hasDestReadBehavior(codec):
    if params.get(MixParameters()).expectReply.get(false):
      return err("no destination read behavior for codec")
    else:
      warn "no destination read behavior for codec", codec

  ok(MixEntryConnection.new(srcMix, destination, codec, params))

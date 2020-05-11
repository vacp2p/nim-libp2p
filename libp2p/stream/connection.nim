## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids
import chronicles, chronos, metrics
import connectiontracker,
       ../multiaddress,
       ../peerinfo,
       ../varint,
       ../vbuffer

type
  Connection* = ref object of RootObj
    peerInfo*: PeerInfo
    observedAddrs*: Multiaddress
    isClosed*: bool
    closeEvent*: AsyncEvent
    when chronicles.enabledLogLevel == LogLevel.TRACE:
      oid*: Oid

  LPStreamError* = object of CatchableError
  LPStreamIncompleteError* = object of LPStreamError
  LPStreamIncorrectDefect* = object of Defect
  LPStreamLimitError* = object of LPStreamError
  LPStreamReadError* = object of LPStreamError
    par*: ref Exception
  LPStreamWriteError* = object of LPStreamError
    par*: ref Exception
  LPStreamEOFError* = object of LPStreamError

  InvalidVarintError* = object of LPStreamError
  MaxSizeError* = object of LPStreamError

declareGauge libp2p_open_connection, "open Connection instances"

proc newLPStreamReadError*(p: ref Exception): ref Exception =
  var w = newException(LPStreamReadError, "Read stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newLPStreamReadError*(msg: string): ref Exception =
  newException(LPStreamReadError, msg)

proc newLPStreamWriteError*(p: ref Exception): ref Exception =
  var w = newException(LPStreamWriteError, "Write stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newLPStreamIncompleteError*(): ref Exception =
  result = newException(LPStreamIncompleteError, "Incomplete data received")

proc newLPStreamLimitError*(): ref Exception =
  result = newException(LPStreamLimitError, "Buffer limit reached")

proc newLPStreamIncorrectDefect*(m: string): ref Exception =
  result = newException(LPStreamIncorrectDefect, m)

proc newLPStreamEOFError*(): ref Exception =
  result = newException(LPStreamEOFError, "Stream EOF!")

method closed*(s: Connection): bool {.base, inline.} =
  s.isClosed

method readExactly*(s: Connection,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.base, async.} =
  doAssert(false, "not implemented!")

method readOnce*(s: Connection,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int]
  {.base, async.} =
  doAssert(false, "not implemented!")

proc readLine*(s: Connection, limit = 0, sep = "\r\n"): Future[string] {.async, deprecated: "todo".} =
  # TODO replace with something that exploits buffering better
  var lim = if limit <= 0: -1 else: limit
  var state = 0

  try:
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
  except LPStreamIncompleteError, LPStreamReadError:
    discard # EOF, in which case we should return whatever we read so far..

proc readVarint*(conn: Connection): Future[uint64] {.async, gcsafe.} =
  var
    varint: uint64
    length: int
    buffer: array[10, byte]

  for i in 0..<len(buffer):
    await conn.readExactly(addr buffer[i], 1)
    let res = PB.getUVarint(buffer.toOpenArray(0, i), length, varint)
    if res == VarintStatus.Success:
      return varint
    if res != VarintStatus.Incomplete:
      break
  if true: # can't end with a raise apparently
    raise (ref InvalidVarintError)(msg: "Cannot parse varint")

proc readLp*(s: Connection, maxSize: int): Future[seq[byte]] {.async, gcsafe.} =
  ## read length prefixed msg, with the length encoded as a varint
  let
    length = await s.readVarint()
    maxLen = uint64(if maxSize < 0: int.high else: maxSize)

  if length > maxLen:
    raise (ref MaxSizeError)(msg: "Message exceeds maximum length")

  if length == 0:
    return

  var res = newSeq[byte](length)
  await s.readExactly(addr res[0], res.len)
  return res

proc writeLp*(s: Connection, msg: string | seq[byte]): Future[void] {.gcsafe.} =
  ## write length prefixed
  var buf = initVBuffer()
  buf.writeSeq(msg)
  buf.finish()
  s.write(buf.buffer)

method write*(s: Connection, msg: seq[byte]) {.base, async, gcsafe.} =
  doAssert(false, "not implemented!")

proc write*(s: Connection, pbytes: pointer, nbytes: int): Future[void] {.deprecated: "seq".} =
  s.write(@(toOpenArray(cast[ptr UncheckedArray[byte]](pbytes), 0, nbytes - 1)))

proc write*(s: Connection, msg: string): Future[void] =
  s.write(@(toOpenArrayByte(msg, 0, msg.high)))

method close*(s: Connection) {.base, async, gcsafe.} =
  trace "about to close connection", closed = s.closed,
                                     peer = if not isNil(s.peerInfo):
                                       s.peerInfo.id else: ""
  if not s.isClosed:
    s.isClosed = true
    inc getConnectionTracker().closed
    trace "connection closed", closed = s.closed,
                               peer = if not isNil(s.peerInfo):
                                 s.peerInfo.id else: ""
    s.closeEvent.fire()
    libp2p_open_connection.dec()

method getObservedAddrs*(c: Connection): Future[MultiAddress] {.base, async, gcsafe.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddrs

proc `$`*(conn: Connection): string =
  if not isNil(conn.peerInfo):
    result = $(conn.peerInfo)

## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids
import chronicles, chronos, strformat
import ../varint,
       ../vbuffer

type
  LPStream* = ref object of RootObj
    isClosed*: bool
    isEof*: bool
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
  LPStreamClosedError* = object of LPStreamError

  InvalidVarintError* = object of LPStreamError
  MaxSizeError* = object of LPStreamError

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

proc newLPStreamClosedError*(): ref Exception =
  result = newException(LPStreamClosedError, "Stream Closed!")

method closed*(s: LPStream): bool {.base, inline.} =
  s.isClosed

method atEof*(s: LPStream): bool {.base, inline.} =
  s.isEof

method readExactly*(s: LPStream,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.base, async.} =
  doAssert(false, "not implemented!")

method readOnce*(s: LPStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int]
  {.base, async.} =
  doAssert(false, "not implemented!")

proc readLine*(s: LPStream, limit = 0, sep = "\r\n"): Future[string] {.async, deprecated: "todo".} =
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

proc readVarint*(conn: LPStream): Future[uint64] {.async, gcsafe.} =
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

proc readLp*(s: LPStream, maxSize: int): Future[seq[byte]] {.async, gcsafe.} =
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

proc writeLp*(s: LPStream, msg: string | seq[byte]): Future[void] {.gcsafe.} =
  ## write length prefixed
  var buf = initVBuffer()
  buf.writeSeq(msg)
  buf.finish()
  s.write(buf.buffer)

method write*(s: LPStream, msg: seq[byte]) {.base, async.} =
  doAssert(false, "not implemented!")

proc write*(s: LPStream, pbytes: pointer, nbytes: int): Future[void] {.deprecated: "seq".} =
  s.write(@(toOpenArray(cast[ptr UncheckedArray[byte]](pbytes), 0, nbytes - 1)))

proc write*(s: LPStream, msg: string): Future[void] =
  s.write(@(toOpenArrayByte(msg, 0, msg.high)))

method close*(s: LPStream)
  {.base, async.} =
  doAssert(false, "not implemented!")

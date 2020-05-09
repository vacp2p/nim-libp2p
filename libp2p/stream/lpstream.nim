## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids
import chronicles, chronos

type
  LPStream* = ref object of RootObj
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

method closed*(s: LPStream): bool {.base, inline.} =
  s.isClosed

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

proc read*(s: LPStream, nbytes: int): Future[seq[byte]] {.async, deprecated: "readExactly".} =
  # This function is deprecated - it was broken and used inappropriately as
  # `readExacltly` in tests and code - tests still need refactoring to remove
  # any calls
  # `read` without nbytes was also incorrectly implemented - it worked more
  # like `readOnce` in that it would not wait for stream to close, in
  # BufferStream in particular - both tests and implementation were broken
  var ret = newSeq[byte](nbytes)
  await readExactly(s, addr ret[0], ret.len)
  return ret

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

method write*(s: LPStream, msg: seq[byte]) {.base, async.} =
  doAssert(false, "not implemented!")

proc write*(s: LPStream, pbytes: pointer, nbytes: int): Future[void] {.deprecated: "seq".} =
  s.write(@(toOpenArray(cast[ptr UncheckedArray[byte]](pbytes), 0, nbytes - 1)))

proc write*(s: LPStream, msg: string): Future[void] =
  s.write(@(toOpenArrayByte(msg, 0, msg.high)))

method close*(s: LPStream)
  {.base, async.} =
  doAssert(false, "not implemented!")

## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

import stew/[endians2, result], options, libp2p/varint
export options

type
  LPStream* = ref object of RootObj
    isClosed*: bool
    closeEvent*: AsyncEvent

  LPStreamError* = object of CatchableError
  LPStreamIncompleteError* = object of LPStreamError
  LPStreamIncorrectError* = object of Defect
  LPStreamLimitError* = object of LPStreamError
  LPStreamReadError* = object of LPStreamError
    par*: ref Exception
  LPStreamWriteError* = object of LPStreamError
    par*: ref Exception
  LPStreamEOFError* = object of LPStreamError

proc newLPStreamReadError*(p: ref Exception): ref Exception {.inline.} =
  var w = newException(LPStreamReadError, "Read stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newLPStreamWriteError*(p: ref Exception): ref Exception {.inline.} =
  var w = newException(LPStreamWriteError, "Write stream failed")
  w.msg = w.msg & ", originated from [" & $p.name & "] " & p.msg
  w.par = p
  result = w

proc newLPStreamIncompleteError*(): ref Exception {.inline.} =
  result = newException(LPStreamIncompleteError, "Incomplete data received")

proc newLPStreamLimitError*(): ref Exception {.inline.} =
  result = newException(LPStreamLimitError, "Buffer limit reached")

proc newLPStreamIncorrectError*(m: string): ref Exception {.inline.} =
  result = newException(LPStreamIncorrectError, m)

proc newLPStreamEOFError*(): ref Exception {.inline.} =
  result = newException(LPStreamEOFError, "Stream EOF!")

proc initLPStream*(v: LPStream) =
  v.closeEvent = newAsyncEvent()

method closed*(s: LPStream): bool {.base, inline.} =
  s.isClosed

method readOnce*(s: LPStream): Future[seq[byte]] {.base, async.} =
  doAssert(false, "not implemented!")

method write*(s: LPStream, msg: seq[byte], msglen = -1) {.base, async.} =
  doAssert(false, "not implemented!")

proc write*(s: LPStream, pbytes: pointer, nbytes: int): Future[void] =
  return s.write(@(toOpenArray(cast[ptr UncheckedArray[byte]](pbytes), 0, nbytes - 1)))

import stew/byteutils
proc write*(s: LPStream, msg: string): Future[void] =
  s.write(msg.toBytes())

method close*(s: LPStream) {.base, async.} =
  if not s.isClosed:
    s.isClosed = true
    s.closeEvent.fire()

type ReadOnce = proc(): Future[seq[byte]] {.gcsafe.}

type StreamBuffer* = ref object
  buf*: seq[byte]
  read*: ReadOnce

func buffer*(s: LPStream): StreamBuffer =
  StreamBuffer(read: proc(): Future[seq[byte]] = s.readOnce())

func consume(buf: var seq[byte], n: int) =
  if n >= buf.len():
    setLen(buf, 0)
  elif n > 0:
    moveMem(addr buf[0], addr buf[n], buf.len - n)
    setLen(buf, buf.len() - n)

proc readOnce*(sb: StreamBuffer): Future[seq[byte]] {.async.} =
  if sb.buf.len() == 0:
    return await sb.read()

  var res = sb.buf # where is the move support when you need it?
  sb.buf.setLen(0)
  return res

proc readMessage*(sb: StreamBuffer, predicate: ReadMessagePredicate): Future[bool] {.async.} =
  var readOnceDone = false
  while true:
    while sb.buf.len() > 0:
      let (consumed, done) = predicate(sb.buf)
      sb.buf.consume(consumed)

      if done:
        return readOnceDone

      if consumed == 0:
        break

    if readOnceDone:
      raise newLPStreamIncompleteError()

    let newData = await sb.read()
    if newData.len() == 0:
      readOnceDone = true
    else:
      # TODO we could run predicate on newData here if buf is empty
      sb.buf.add newData

proc readBigEndian*(sb: StreamBuffer, T: type SomeUnsignedInt): Future[Option[T]] {.async.} =
  var res: Result[T, ref CatchableError]

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    if data.len() >= sizeof(T):
      res.ok(T.fromBytesBE(data))
      (sizeof(T), true)
    else:
      (0, false)

  if await sb.readMessage(predicate):
    return none(T)

  return some(res[])

proc readVarint*(sb: StreamBuffer): Future[Option[uint64]] {.async.} =
  var res: Result[uint64, ref CatchableError]

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    var
      consumed: int
      len: uint64

    let x = PB.getUVarint(data, consumed, len)
    case x
    of VarintStatus.Success:
      res.ok(len)
      (consumed, true)
    of VarintStatus.Incomplete:
      (0, false)
    else:
      res.err((ref CatchableError)(msg: $x))
      (0, true)

  if await sb.readMessage(predicate):
    return none(uint64)

  return some(res[])

proc readExactly*(sb: StreamBuffer, n: int): Future[Option[seq[byte]]] {.async.} =
  var res: Result[seq[byte], ref CatchableError]

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    if data.len >= n:
      res.ok(data[0..<n])
      (n, true)
    else:
      (0, false)

  if await sb.readMessage(predicate):
    return none(seq[byte])

  return some(res[])

proc readVarintMessage*(sb: StreamBuffer, maxLen: int): Future[Option[seq[byte]]] {.async.} =
  doAssert maxLen > 0

  let len = await sb.readVarint()
  if len.isNone():
    return none(seq[byte])

  if len.get() > maxLen.uint64:
    raise newLPStreamIncompleteError()

  let res = await sb.readExactly(len.get().int)
  if res.isNone(): # Stream ended between varint and message - this is wrong
    raise newLPStreamIncompleteError()

  return res

proc readBigEndianMessage32*(sb: StreamBuffer, maxLen: int): Future[Option[seq[byte]]] {.async.} =
  doAssert maxLen > 0

  let len = await sb.readBigEndian(uint32)
  if len.isNone():
    return none(seq[byte])

  if len.get() > maxLen.uint64:
    raise newLPStreamIncompleteError()

  let res = await sb.readExactly(len.get().int)
  if res.isNone(): # Stream ended between varint and message - this is wrong
    raise newLPStreamIncompleteError()

  return res

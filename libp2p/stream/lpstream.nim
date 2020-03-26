## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import stew/byteutils
import chronos
import stew/[endians2, result, bitops2], options, ../varint
export options

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

proc newLPStreamEOFError*(): ref LPStreamEOFError {.inline.} =
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

proc write*(s: LPStream, msg: string): Future[void] =
  s.write(msg.toBytes())

method close*(s: LPStream) {.base, async.} =
  if not s.isClosed:
    s.isClosed = true
    s.closeEvent.fire()

type ReadOnce = proc(): Future[seq[byte]] {.gcsafe.}

type
  StreamBuf* = object
    buf: seq[byte]
    rpos: int
    wpos: int

template len*(v: StreamBuf): int =
  v.wpos - v.pos

template data*(v: StreamBuf): openArray[byte] =
  debugEcho v.rpos, " ", v.wpos, " ", v.buf.len
  v.buf.toOpenArray(v.rpos, v.wpos - 1)

template len*(v: StreamBuf): int =
  v.wpos - v.rpos

func grow(v: var StreamBuf, n: int) =
  if v.rpos == v.wpos:
    # All data has been consumed, reset positions
    v.rpos = 0
    v.wpos = 0

  if v.buf.len - v.wpos < n:
    if v.rpos > 0:
      # We've consumed some data so we'll try to move that data to the beginning
      # of the buffer, hoping that this will clear up enough capacity to avoid
      # reallocation
      moveMem(addr v.buf[0], addr v.buf[v.rpos], v.wpos - v.rpos)
      v.wpos -= v.rpos
      v.rpos = 0

      if v.buf.len - v.wpos >= n:
        return

    # TODO this is inefficient - `setLen` will copy all data of buf, even though
    #      we know that only a part of it contains "valid" data
    v.buf.setLen(nextPow2(max(64, v.wpos + n).uint64).int)

template prepare*(v: var StreamBuf, n: int): var openArray[byte] =
  ## Return a buffer that is at least `n` bytes long
  v.grow(n)

  v.buf.toOpenArray(v.wpos, v.buf.len - 1)

template commit*(v: var StreamBuf, n: int) =
  v.wpos += n

func add*(v: var StreamBuf, data: openArray[byte]) =
  v.grow(data.len)
  copyMem(addr v.buf[v.wpos], unsafeAddr data[0], data.len)
  v.commit(data.len)

func consume*(v: var StreamBuf, n: int) =
  v.rpos += n

type StreamBuffer* = ref object
  buf*: StreamBuf
  read*: ReadOnce

func buffer*(s: LPStream): StreamBuffer =
  StreamBuffer(read: proc(): Future[seq[byte]] = s.readOnce())

proc readOnce*(sb: StreamBuffer): Future[seq[byte]] {.async.} =
  if sb.buf.len() == 0:
    return await sb.read()

  var res = @(sb.buf.data())
  sb.buf.consume(res.len)
  return res

proc readMessage*(sb: StreamBuffer, predicate: ReadMessagePredicate): Future[bool] {.async.} =
  # In this variation of readMessage, the predicate must move data out of the
  # buffer using a closure like so:
  # var v
  # x.readMessage(proc(data)... = v = decode(data))

  var readOnceDone = false
  while true:
    while sb.buf.len() > 0:
      let (consumed, done) = predicate(sb.buf.data())
      sb.buf.consume(consumed)

      if done:
        return readOnceDone

      if consumed == 0: # No progress, need more data
        break

    if readOnceDone: # We need more data, but there is no more data - irregular!
      # TODO Should we raise in this case? Could also report end-of-stream
      raise newLPStreamIncompleteError()

    let newData = await sb.read()
    if newData.len() == 0:
      readOnceDone = true
    else:
      # TODO we could run predicate on newData here if buf is empty
      sb.buf.add newData

proc readBigEndian*(sb: StreamBuffer, T: type SomeUnsignedInt): Future[Option[T]] {.async.} =
  var res: T

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    if data.len() >= sizeof(T):
      res = T.fromBytesBE(data)
      (sizeof(T), true)
    else:
      (0, false)

  if await sb.readMessage(predicate):
    return none(T)

  return some(res)

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
  var res: seq[byte]

  proc predicate(data: openArray[byte]): tuple[consumed: int, done: bool] =
    if data.len >= n:
      res = data[0..<n]
      (n, true)
    else:
      (0, false)

  if await sb.readMessage(predicate):
    return none(seq[byte])

  return some(res)

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

type  ReadMessagePredicate2*[T] = proc (data: openarray[byte]):
  tuple[consumed: int, value: Option[T]] {.gcsafe, raises: [].}

proc readMessage2*[T](sb: StreamBuffer, predicate: ReadMessagePredicate2[T]): Future[Option[T]] {.async.} =
  # This version of readMessage allows returning "end-of-stream or a value" naturally:
  # let v = await x.readMessage2(..., predicate)
  # if v.isNone: streamClosed()
  #
  # If there's a decoding error, it has to be moved out through a closure:
  # var error: SomeError
  # let v = await x.readMessage2(..., predicate)
  # if v.isNone: checkError(error)

  var readOnceDone = false
  while true:
    while sb.buf.len() > 0:
      let (consumed, value) = predicate(sb.buf.data())
      sb.buf.consume(consumed)

      if value.isSome():
        return value

      if consumed == 0: # No progress, need more data
        break

    if readOnceDone:
      raise newLPStreamIncompleteError()

    let newData = await sb.read()
    if newData.len() == 0:
      readOnceDone = true
    else:
      # TODO we could run predicate on newData here if buf is empty
      sb.buf.add newData

proc readBigEndian2*(sb: StreamBuffer, T: type SomeUnsignedInt): Future[Option[T]] {.async.} =
  proc predicate(data: openArray[byte]): tuple[consumed: int, value: Option[T]] =
    if data.len() >= sizeof(T):
      (sizeof(T), some(T.fromBytesBE(data)))
    else:
      (0, none(T))

  return sb.readMessage(predicate)

proc readVarint2*(sb: StreamBuffer): Future[Option[uint64]] {.async.} =
  # We need to use a Result here because we need to stop reading in case an
  # invalid varint is encountered in the stream
  type Res = Result[uint64, ref CatchableError]

  proc predicate(data: openArray[byte]): tuple[consumed: int, value: Option[Res]] =
    var
      consumed: int
      len: uint64

    let x = PB.getUVarint(data, consumed, len)
    case x
    of VarintStatus.Success:
      (consumed, some(Res.ok(len)))
    of VarintStatus.Incomplete:
      (0, none(Res)) # More data please
    else:
      (0, some(Res.err((ref CatchableError)(msg: $x)))) # Error!

  let res = await sb.readMessage2(predicate)
  if res.isNone:
    return none(uint64)

  return some(res.get()[]) # This will raise if res is faulty!

type  ReadMessagePredicate3*[T, E] = proc (data: openarray[byte]):
  tuple[consumed: int, value: Option[Result[T, E]]] {.gcsafe, raises: [].}

proc readMessage3*[T, E](sb: StreamBuffer, predicate: ReadMessagePredicate3[T, E]): Future[Option[T]] {.async.} =
  # Here, we can return additional error information that will be set in the
  # future:
  # try:
  #   let v = await x.readMessage3(..., predicate)
  #   if v.isNone: streamClosed()
  # except SomeError as e:
  #   echo e

  var readOnceDone = false
  while true:
    while sb.buf.len() > 0:
      let (consumed, done) = predicate(sb.buf.data())
      sb.buf.consume(consumed)

      if done.isSome:
        return some(done.get()[]) # Raises!

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

proc readVarint3*(sb: StreamBuffer): Future[Option[uint64]] {.async.} =
  type Res = Result[uint64, ref ValueError]

  proc predicate(data: openArray[byte]): tuple[consumed: int, value: Option[Res]] =
    var
      consumed: int
      len: uint64

    let x = PB.getUVarint(data, consumed, len)
    case x
    of VarintStatus.Success:
      (consumed, some(Res.ok(len)))
    of VarintStatus.Incomplete:
      (0, none(Res))
    else:
      (0, some(Res.err((ref ValueError)(msg: $x))))

  return await sb.readMessage3(predicate)

type ReadMessagePredicate4*[T] = proc (data: openarray[byte]):
  Option[tuple[consumed: int, value: Option[T]]] {.gcsafe, raises: [].}

proc readMessage4*[T](sb: StreamBuffer, predicate: ReadMessagePredicate4[T]): Future[Option[T]] {.async.} =
  # This variation allows the predicate to tell the loop that the stream is dead
  # but doesn't raise any exceptions
  #
  # try:
  #   let v = await x.readMessage2(..., predicate)
  #   if v.isNone: streamClosed()
  # except SomeError as e:
  #   echo e

  var readOnceDone = false
  while true:
    while sb.buf.len() > 0:
      let data = predicate(sb.buf.data())
      if data.isNone:
        return none(T)

      sb.buf.consume(data.get().consumed)

      if data.get().value.isSome():
        return data.get().value

      if data.get().consumed == 0:
        break

    if readOnceDone:
      raise newLPStreamIncompleteError()

    let newData = await sb.read()
    if newData.len() == 0:
      readOnceDone = true
    else:
      # TODO we could run predicate on newData here if buf is empty
      sb.buf.add newData

proc readVarint4*(sb: StreamBuffer): Future[Option[uint64]] {.async.} =
  proc predicate(data: openArray[byte]): Option[tuple[consumed: int, value: Option[uint64]]] =
    var
      consumed: int
      len: uint64

    let x = PB.getUVarint(data, consumed, len)
    case x
    of VarintStatus.Success:
      some((consumed, some(len)))
    of VarintStatus.Incomplete:
      some((0, none(uint64)))
    else:
      # TODO here one would log the error
      none(tuple[consumed: int, value: Option[uint64]])

  return await sb.readMessage4(predicate)

type  ReadMessagePredicate5*[T] = proc (data: openarray[byte]):
  tuple[consumed: int, value: Option[T]] {.gcsafe, raises: [CatchableError].}

proc readMessage5*[T](sb: StreamBuffer, predicate: ReadMessagePredicate5[T]): Future[Option[T]] {.async.} =
  # Here we let the predicate raise

  var readOnceDone = false
  while true:
    while sb.buf.len() > 0:
      let (consumed, done) = predicate(sb.buf.data())
      sb.buf.consume(consumed)

      if done.isSome:
        return done

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

proc readVarint5*(sb: StreamBuffer): Future[Option[uint64]] {.async.} =
  proc predicate(data: openArray[byte]): tuple[consumed: int, value: Option[uint64]] =
    var
      consumed: int
      len: uint64

    let x = PB.getUVarint(data, consumed, len)
    case x
    of VarintStatus.Success:
      (consumed, some(len))
    of VarintStatus.Incomplete:
      (0, none(uint64))
    else:
      raise (ref ValueError)(msg: $x)

  return await sb.readMessage5(predicate)

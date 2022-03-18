## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# Could be in chronos

import std/[strformat, sequtils]
import stew/byteutils
import chronos, chronicles

## Sync part
##
## Ring buffer where writep == readp means empty
## and writep + & == readp means full.
## This wastes a slot of the buf that will never be used
##
## Instead of doing clever modulos, ifs are used for clarity
type
  RingBuffer*[T] = object
    buf: seq[T] # Data store
    readp: int # Reading position
    writep: int # Writing position
    full: bool

func isFull*[T](rb: RingBuffer[T]): bool =
  rb.full

func isEmpty*[T](rb: RingBuffer[T]): bool =
  rb.writep == rb.readp and not rb.full

func len*[T](rb: RingBuffer[T]): int =
  if rb.full: rb.buf.len
  elif rb.writep < rb.readp: rb.writep + rb.buf.len - rb.readp
  else: rb.writep - rb.readp

proc write*[T](rb: var RingBuffer[T], data: openArray[T]): int =
  ## Add data

  let
    readPosRelative =
      if rb.readp < rb.writep: rb.readp + rb.buf.len
      else: rb.readp

    canAddBeforeFull =
      if rb.isEmpty: min(rb.buf.len, data.len)
      else: min(readPosRelative - rb.writep, data.len)

    canAddBeforeSplit = min(rb.buf.len - rb.writep, data.len)

    canAdd = min(canAddBeforeFull, canAddBeforeSplit)

  copyMem(addr rb.buf[rb.writep], unsafeAddr data[0], canAdd)
  rb.writep += canAdd

  if canAdd < canAddBeforeFull:
    let splittedCount = canAddBeforeFull - canAddBeforeSplit
    copyMem(addr rb.buf[0], unsafeAddr data[canAdd], splittedCount)
    rb.writep = splittedCount

  if rb.writeP == rb.buf.len: rb.writeP = 0

  if rb.writeP == rb.readP: rb.full = true

  canAddBeforeFull

proc read_internal[T](rb: var RingBuffer[T], buffer: var openArray[T]): int =
  ## This will chunk at the end of the circular buffer
  ## to avoid allocations
  let
    continuousInBuffer =
      if rb.writep < rb.readp or rb.full: rb.buf.len - rb.readp
      else: rb.writep - rb.readp
    canRead = min(buffer.len, continuousInBuffer)

  copyMem(unsafeAddr buffer[0], addr rb.buf[rb.readp], canRead)
  rb.readp += canRead
  if rb.readp == rb.buf.len: rb.readp = 0
  rb.full = false
  canRead

proc read*[T](rb: var RingBuffer[T], buffer: var openArray[T]): int =
  rb.read_internal(buffer)

proc readAll*[T](rb: var RingBuffer[T]): seq[T] =
  result = newSeq[T](rb.len())
  let readFirst = rb.read_internal(result)
  if readFirst < result.len:
    discard rb.read_internal(result.toOpenArray(readFirst, result.len - 1))

proc init*[T](R: typedesc[RingBuffer[T]], size: int): R =
  RingBuffer[T](
    buf: newSeq[T](size)
  )

when isMainModule:
  var totalI = 0
  proc getSeq(i: int): seq[byte] =
    for x in 0..<i: result.add((totalI + x).byte)
    totalI.inc(i)
  #var rb = RingBuffer[byte].init(12)
  #var buffer = newSeq[byte](30)
  #echo "Sync"
  #echo rb.write(getSeq(3))
  #echo rb.write(getSeq(6))
  #echo rb.readAll()
  #echo rb.write(getSeq(6))
  #echo rb
  #echo rb.write(getSeq(6))
  #echo rb.readAll()

  #echo rb.write(getSeq(30))
  #echo rb

## Async part
type
  AsyncRingBuffer*[T] = ref object
    ring: RingBuffer[T]
    #TODO handle a single getter
    getters: seq[Future[void]]
    putters: seq[Future[void]]

# Borrows
func isFull*[T](rb: AsyncRingBuffer[T]): bool = rb.ring.isFull()
func isEmpty*[T](rb: AsyncRingBuffer[T]): bool = rb.ring.isEmpty()
func len*[T](rb: AsyncRingBuffer[T]): int = rb.ring.len()

# Stolen from chronos
proc wakeupNext(waiters: var seq[Future[void]]) {.inline.} =
  var i = 0
  while i < len(waiters):
    var waiter = waiters[i]
    inc(i)

    if not(waiter.finished()):
      waiter.complete()
      break

  if i > 0:
    waiters.delete(0, i - 1)

#proc write*[T](rb: AsyncRingBuffer[T], data: seq[T]) {.async.} =
#  # First, get a slot
#  while rb.isFull():
#    var putter = newFuture[void]("RingBuffer.write")
#    rb.putters.add(putter)
#    await putter
#
#  # Now we must write everything without getting our slot stollen
#  var written = rb.ring.write(data)
#  rb.getters.wakeUpNext()
#
#  while written < data.len:
#    var putter = newFuture[void]("RingBuffer.write")
#    # We are prioritary
#    rb.putters.insert(putter, 0)
#    await putter
#
#    written += rb.ring.write(data.toOpenArray(written, data.len - 1))
#    rb.getters.wakeUpNext()
#
#  if not rb.isFull(): #Room for the next one
#    rb.putters.wakeUpNext()

proc write*[T](rb: AsyncRingBuffer[T], data: ptr UncheckedArray[T], size: int) {.async.} =
  # First, get a slot
  while rb.isFull():
    var putter = newFuture[void]("RingBuffer.write")
    rb.putters.add(putter)
    await putter

  # Now we must write everything without getting our slot stollen
  var written = rb.ring.write(toOpenArray(data, 0, size))
  rb.getters.wakeUpNext()

  while written < size:
    var putter = newFuture[void]("RingBuffer.write")
    # We are prioritary
    rb.putters.insert(putter, 0)
    await putter

    written += rb.ring.write(data.toOpenArray(written, size - 1))
    rb.getters.wakeUpNext()

  if not rb.isFull(): #Room for the next one
    rb.putters.wakeUpNext()

proc read*[T](rb: AsyncRingBuffer[T], maxRead: int = 10000): Future[seq[T]] {.async.} =
  while rb.isEmpty():
    var getter = newFuture[void]("RingBuffer.read")
    rb.getters.add(getter)
    await getter

  let res = rb.ring.readAll()

  rb.putters.wakeUpNext()
  # Since we read everything, we won't wake up other readers

  return res

proc new*[T](R: typedesc[AsyncRingBuffer[T]], size: int): R =
  AsyncRingBuffer[T](
    ring: RingBuffer[T].init(size)
  )

when isMainModule:
  proc testA {.async.} =
    var rb = AsyncRingBuffer[byte].new(3)
    #await rb.write(getSeq(6))
    let toSend = getSeq(30)
    let tooBigWrite = rb.write(cast[ptr UncheckedArray[byte]](unsafeAddr toSend[0]), 30)# and rb.write(UncheckedArray(getSeq(70)), 70)
    while rb.len > 0 or not tooBigWrite.finished:
      let reader = rb.read()
      await reader or tooBigWrite
      if reader.finished:
        echo await reader
      else:
        await reader.cancelAndWait()

  echo "Async"
  waitFor(testA())

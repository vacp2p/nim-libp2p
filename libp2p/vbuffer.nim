# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module implements variable buffer.

{.push raises: [].}

import varint, strutils

type VBuffer* = object
  buffer*: seq[byte]
  offset*: int

template isEmpty*(vb: VBuffer): bool =
  ## Returns ``true`` if buffer ``vb`` is empty.
  len(vb.buffer) - vb.offset <= 0

template isEnough*(vb: VBuffer, length: int): bool =
  ## Returns ``true`` if buffer ``vb`` holds at least ``length`` bytes.
  len(vb.buffer) - vb.offset - length >= 0

proc high*(vb: VBuffer): int =
  ## Returns number of bytes left in buffer ``vb``.
  let r = vb.buffer.high - vb.offset
  doAssert(r >= 0)
  r

proc len*(vb: VBuffer): int =
  ## Returns number of bytes left in buffer ``vb``.
  let r = len(vb.buffer) - vb.offset
  doAssert(r >= 0)
  r

proc initVBuffer*(data: seq[byte], offset = 0): VBuffer =
  ## Initialize VBuffer with shallow copy of ``data``.
  VBuffer(buffer: data, offset: offset)

proc initVBuffer*(data: openArray[byte], offset = 0): VBuffer =
  ## Initialize VBuffer with copy of ``data``.
  var buf = newSeqUninit[byte](len(data))
  if len(data) > 0:
    copyMem(addr buf[0], addr data[0], len(data))
  VBuffer(buffer: buf, offset: offset)

proc initVBuffer*(cap: int = 128): VBuffer =
  ## Initialize empty VBuffer.
  doAssert(cap >= 0)
  VBuffer(buffer: newSeqOfCap[byte](cap))

proc writePBVarint*(vb: var VBuffer, value: PBSomeUVarint) =
  ## Write ``value`` as variable unsigned integer.
  var length = 0
  var v = value and cast[type(value)](0xFFFF_FFFF_FFFF_FFFF)
  vb.buffer.setLen(len(vb.buffer) + vsizeof(v))
  let res = PB.putUVarint(toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, v)
  doAssert(res.isOk())
  vb.offset += length

proc writeLPVarint*(vb: var VBuffer, value: LPSomeUVarint) =
  ## Write ``value`` as variable unsigned integer.
  var length = 0
  # LibP2P varint supports only 63 bits.
  var v = value and cast[type(value)](0x7FFF_FFFF_FFFF_FFFF)
  vb.buffer.setLen(len(vb.buffer) + vsizeof(v))
  let res = LP.putUVarint(toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, v)
  doAssert(res.isOk())
  vb.offset += length

proc writeVarint*(vb: var VBuffer, value: LPSomeUVarint) =
  writeLPVarint(vb, value)

proc writeSeq*[T: byte | char](vb: var VBuffer, value: openArray[T]) =
  ## Write array ``value`` to buffer ``vb``, value will be prefixed with
  ## varint length of the array.
  var length = 0
  vb.buffer.setLen(len(vb.buffer) + vsizeof(uint(len(value))) + len(value))
  let res = LP.putUVarint(
    toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, uint(len(value))
  )
  doAssert(res.isOk())
  vb.offset += length
  if len(value) > 0:
    copyMem(addr vb.buffer[vb.offset], addr value[0], len(value))
    vb.offset += len(value)

proc writeArray*[T: byte | char](vb: var VBuffer, value: openArray[T]) =
  ## Write array ``value`` to buffer ``vb``, value will NOT be prefixed with
  ## varint length of the array.
  if len(value) > 0:
    vb.buffer.setLen(len(vb.buffer) + len(value))
    copyMem(addr vb.buffer[vb.offset], addr value[0], len(value))
    vb.offset += len(value)

proc finish*(vb: var VBuffer) =
  ## Finishes ``vb``.
  vb.offset = 0

proc peekVarint*(vb: var VBuffer, value: var LPSomeUVarint): int =
  ## Peek unsigned integer from buffer ``vb`` and store result to ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` or ``-1`` on error.
  var r = -1
  value = cast[type(value)](0)
  var length = 0
  if not vb.isEmpty():
    let res =
      LP.getUVarint(toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, value)
    if res.isOk():
      r = length
  r

proc peekSeq*[T: string | seq[byte]](vb: var VBuffer, value: var T): int =
  ## Peek length prefixed array from buffer ``vb`` and store result to
  ## ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` or ``-1`` on error.
  var r = -1
  value.setLen(0)
  var length = 0
  var size = 0'u64
  if not vb.isEmpty() and
      LP
      .getUVarint(toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, size)
      .isOk():
    vb.offset += length
    r = length
    if vb.isEnough(int(size)):
      value.setLen(size)
      if size > 0'u64:
        copyMem(addr value[0], addr vb.buffer[vb.offset], size)
      r += int(size)
    vb.offset -= length
  r

proc peekArray*[T: char | byte](vb: var VBuffer, value: var openArray[T]): int =
  ## Peek array from buffer ``vb`` and store result to ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` or ``-1`` on error.
  let length = len(value)
  if vb.isEnough(length):
    if length > 0:
      copyMem(addr value[0], addr vb.buffer[vb.offset], length)
    length
  else:
    -1

proc readVarint*(vb: var VBuffer, value: var LPSomeUVarint): int {.inline.} =
  ## Read unsigned integer from buffer ``vb`` and store result to ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` or ``-1`` on error.
  let r = vb.peekVarint(value)
  if r != -1:
    vb.offset += r
  r

proc readSeq*[T: string | seq[byte]](vb: var VBuffer, value: var T): int {.inline.} =
  ## Read length prefixed array from buffer ``vb`` and store result to
  ## ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` or ``-1`` on error.
  let r = vb.peekSeq(value)
  if r != -1:
    vb.offset += r
  r

proc readArray*[T: char | byte](
    vb: var VBuffer, value: var openArray[T]
): int {.inline.} =
  ## Read array from buffer ``vb`` and store result to ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` or ``-1`` on error.
  let r = vb.peekArray(value)
  if r != -1:
    vb.offset += r
  r

proc `$`*(vb: VBuffer): string =
  ## Return hexadecimal string representation of buffer ``vb``.
  let length = (len(vb.buffer) - vb.offset) * 2
  var s = newStringOfCap(length)
  for i in 0 ..< len(vb.buffer):
    s.add(toHex(vb.buffer[i]))
  s

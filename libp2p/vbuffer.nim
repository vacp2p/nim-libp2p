# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module implements variable buffer.

{.push raises: [].}

import varint, strutils, results
import ./utils/sequninit

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
  result = vb.buffer.high - vb.offset
  doAssert(result >= 0)

proc len*(vb: VBuffer): int =
  ## Returns number of bytes left in buffer ``vb``.
  result = len(vb.buffer) - vb.offset
  doAssert(result >= 0)

proc initVBuffer*(data: seq[byte], offset = 0): VBuffer =
  ## Initialize VBuffer with shallow copy of ``data``.
  result.buffer = data
  result.offset = offset

proc initVBuffer*(data: openArray[byte], offset = 0): VBuffer =
  ## Initialize VBuffer with copy of ``data``.
  result.buffer = newSeqUninit[byte](len(data))
  if len(data) > 0:
    copyMem(addr result.buffer[0], unsafeAddr data[0], len(data))
  result.offset = offset

proc initVBuffer*(cap: int = 128): VBuffer =
  ## Initialize empty VBuffer.
  doAssert(cap >= 0)
  result.buffer = newSeqOfCap[byte](cap)

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
    copyMem(addr vb.buffer[vb.offset], unsafeAddr value[0], len(value))
    vb.offset += len(value)

proc writeArray*[T: byte | char](vb: var VBuffer, value: openArray[T]) =
  ## Write array ``value`` to buffer ``vb``, value will NOT be prefixed with
  ## varint length of the array.
  if len(value) > 0:
    vb.buffer.setLen(len(vb.buffer) + len(value))
    copyMem(addr vb.buffer[vb.offset], unsafeAddr value[0], len(value))
    vb.offset += len(value)

proc finish*(vb: var VBuffer) =
  ## Finishes ``vb``.
  vb.offset = 0

proc peekVarint*(vb: var VBuffer, value: var LPSomeUVarint): Opt[int] =
  ## Peek unsigned integer from buffer ``vb`` and store result to ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` on success, or
  ## ``Opt.none(int)`` on error.
  value = cast[type(value)](0)
  var length = 0
  if not vb.isEmpty():
    let res =
      LP.getUVarint(toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, value)
    if res.isOk():
      return Opt.some(length)
  Opt.none(int)

proc peekSeq*[T: string | seq[byte]](vb: var VBuffer, value: var T): Opt[int] =
  ## Peek length prefixed array from buffer ``vb`` and store result to
  ## ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` on success, or
  ## ``Opt.none(int)`` on error.
  value.setLen(0)
  var length = 0
  var size = 0'u64
  if not vb.isEmpty() and
      LP
      .getUVarint(toOpenArray(vb.buffer, vb.offset, vb.buffer.high), length, size)
      .isOk():
    vb.offset += length
    var totalRead = length
    if vb.isEnough(int(size)):
      value.setLen(size)
      if size > 0'u64:
        copyMem(addr value[0], addr vb.buffer[vb.offset], size)
      totalRead += int(size)
      vb.offset -= length
      return Opt.some(totalRead)
    vb.offset -= length
  Opt.none(int)

proc peekArray*[T: char | byte](
    vb: var VBuffer, value: var openArray[T]
): Opt[int] =
  ## Peek array from buffer ``vb`` and store result to ``value``.
  ##
  ## This procedure will not adjust internal offset.
  ##
  ## Returns number of bytes peeked from ``vb`` on success, or
  ## ``Opt.none(int)`` on error.
  let length = len(value)
  if vb.isEnough(length):
    if length > 0:
      copyMem(addr value[0], addr vb.buffer[vb.offset], length)
    return Opt.some(length)
  Opt.none(int)

proc readVarint*(vb: var VBuffer, value: var LPSomeUVarint): Opt[int] {.inline.} =
  ## Read unsigned integer from buffer ``vb`` and store result to ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` on success, or
  ## ``Opt.none(int)`` on error.
  let readLength = vb.peekVarint(value).valueOr:
    # read* procs intentionally keep the same coarse-grained failure contract as
    # peek*: failure is represented as Opt.none(int).
    return Opt.none(int)
  vb.offset += readLength
  Opt.some(readLength)

proc readSeq*[T: string | seq[byte]](vb: var VBuffer, value: var T): Opt[int] {.inline.} =
  ## Read length prefixed array from buffer ``vb`` and store result to
  ## ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` on success, or
  ## ``Opt.none(int)`` on error.
  let readLength = vb.peekSeq(value).valueOr:
    # read* procs intentionally keep the same coarse-grained failure contract as
    # peek*: failure is represented as Opt.none(int).
    return Opt.none(int)
  vb.offset += readLength
  Opt.some(readLength)

proc readArray*[T: char | byte](
    vb: var VBuffer, value: var openArray[T]
): Opt[int] {.inline.} =
  ## Read array from buffer ``vb`` and store result to ``value``.
  ##
  ## Returns number of bytes consumed from ``vb`` on success, or
  ## ``Opt.none(int)`` on error.
  let readLength = vb.peekArray(value).valueOr:
    # read* procs intentionally keep the same coarse-grained failure contract as
    # peek*: failure is represented as Opt.none(int).
    return Opt.none(int)
  vb.offset += readLength
  Opt.some(readLength)

proc `$`*(vb: VBuffer): string =
  ## Return hexadecimal string representation of buffer ``vb``.
  let length = (len(vb.buffer) - vb.offset) * 2
  result = newStringOfCap(length)
  for i in 0 ..< len(vb.buffer):
    result.add(toHex(vb.buffer[i]))

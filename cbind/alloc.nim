# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

# Shared Memory Management
#
# This file implements procedures for allocating and deallocating shared memory
# used for communication between client and library threads.

import ../libp2p/utils/sequninit
import ./ffi_types

## Can be shared safely between threads
type SharedSeq*[T] = object
  data: ptr UncheckedArray[T]
  len: int

proc len*(s: SharedSeq): int =
  s.len

template deallocCStringArray*(arrPtr: ptr cstring, len: csize_t) =
  if not arrPtr.isNil():
    let arr = cast[ptr UncheckedArray[cstring]](arrPtr)
    for i in 0 ..< int(len):
      if not arr[i].isNil():
        deallocShared(arr[i])
    deallocShared(arr)

proc alloc*(str: cstring): cstring =
  # Byte allocation from the given address.
  # There should be the corresponding manual deallocation with deallocShared !
  if str.isNil():
    var ret = cast[cstring](allocShared(1)) # Allocate memory for the null terminator
    ret[0] = '\0' # Set the null terminator
    return ret

  let ret = cast[cstring](allocShared(len(str) + 1))
  copyMem(ret, str, len(str) + 1)
  return ret

proc alloc*(str: string): cstring =
  ## Byte allocation from the given address.
  ## There should be the corresponding manual deallocation with deallocShared !
  var ret = cast[cstring](allocShared(str.len + 1))
  let s = cast[seq[char]](str)
  for i in 0 ..< str.len:
    ret[i] = s[i]
  ret[str.len] = '\0'
  return ret

proc allocCStringArrayFromSeq*(addrs: seq[string]): ptr cstring =
  if addrs.len == 0:
    return nil
  result = cast[ptr cstring](allocShared(sizeof(cstring) * addrs.len))
  let arr = cast[ptr UncheckedArray[cstring]](result)
  for i, addrStr in addrs:
    arr[i] = addrStr.alloc()

proc allocCStringArrayFromCArray*(src: ptr cstring, len: csize_t): ptr cstring =
  if src.isNil() or len == 0:
    return nil
  result = cast[ptr cstring](allocShared(sizeof(cstring) * int(len)))
  let srcArr = cast[ptr UncheckedArray[cstring]](src)
  let dstArr = cast[ptr UncheckedArray[cstring]](result)
  for i in 0 ..< int(len):
    dstArr[i] = srcArr[i].alloc()

proc allocSharedSeq*[T](s: seq[T]): SharedSeq[T] =
  let data = allocShared(sizeof(T) * s.len)
  if s.len != 0:
    copyMem(data, s[0].addr, sizeof(T) * s.len)
  return (cast[ptr UncheckedArray[T]](data), s.len)

proc deallocSharedSeq*[T](s: var SharedSeq[T]) =
  defer:
    s.len = 0

  if s.data.isNil():
    return

  when T is cstring:
    # For array of cstrings, deallocate each string first
    for i in 0 ..< s.len:
      if not s.data[i].isNil():
        # Deallocate each cstring
        deallocShared(s.data[i])

  deallocShared(s.data)

proc toSeq*[T](s: SharedSeq[T]): seq[T] =
  ## Creates a seq[T] from a SharedSeq[T]. No explicit dealloc is required
  ## as req[T] is a GC managed type.
  if s.len == 0:
    return newSeq[T]()

  when T is Natural:
    var ret = newSeqUninit[T](s.len)
    copyMem(addr ret[0], addr s.data[0], s.len * sizeof(T))
    return ret

  return @(s.data.toOpenArray(0, s.len - 1))

proc allocSharedSeqFromCArray*[T](arr: ptr T, len: int): SharedSeq[T] =
  ## Creates a SharedSeq[T] from a C array pointer and length.
  ## The data is copied to shared memory.
  ## There should be a corresponding manual deallocation with deallocSharedSeq!
  if arr.isNil() or len <= 0:
    return SharedSeq[T](data: nil, len: 0)

  when T is cstring:
    # Special handling for arrays of cstrings
    let data = cast[ptr UncheckedArray[cstring]](allocShared(sizeof(cstring) * len))
    let cstrArr = cast[ptr UncheckedArray[cstring]](arr)

    for i in 0 ..< len:
      # Use the existing alloc proc to properly allocate each cstring
      data[i] = cstrArr[i].alloc()

    return SharedSeq[T](data: data, len: len)
  else:
    # Original handling for non-cstring types
    let data = allocShared(sizeof(T) * len)
    copyMem(data, arr, sizeof(T) * len)
    return SharedSeq[T](data: cast[ptr UncheckedArray[T]](data), len: len)

proc deallocReadResponse*(res: ptr ReadResponse) =
  if res.isNil():
    return

  if res[].data != nil:
    deallocShared(res[].data)

  deallocShared(res)

proc allocReadResponse*(data: seq[byte]): ptr ReadResponse =
  let res = cast[ptr ReadResponse](createShared(ReadResponse, 1))
  if data.len == 0:
    res[].data = nil
    res[].dataLen = 0
    return res

  res[].dataLen = data.len.csize_t
  res[].data = cast[ptr byte](allocShared(data.len))
  copyMem(res[].data, addr data[0], data.len)
  res

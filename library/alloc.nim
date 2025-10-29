# Shared Memory Management
#
# This file implements procedures for allocating and deallocating shared memory
# used for communication between client and library threads.

## Can be shared safely between threads
type SharedSeq*[T] = tuple[data: ptr UncheckedArray[T], len: int]

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

proc allocSharedSeq*[T](s: seq[T]): SharedSeq[T] =
  let data = allocShared(sizeof(T) * s.len)
  if s.len != 0:
    copyMem(data, unsafeAddr s[0], s.len)
  return (cast[ptr UncheckedArray[T]](data), s.len)

proc deallocSharedSeq*[T](s: var SharedSeq[T]) =
  if not s.data.isNil():
    when T is cstring:
      # For array of cstrings, deallocate each string first
      for i in 0 ..< s.len:
        if not s.data[i].isNil():
          # Deallocate each cstring
          deallocShared(s.data[i])

    deallocShared(s.data)
  s.len = 0

proc toSeq*[T](s: SharedSeq[T]): seq[T] =
  ## Creates a seq[T] from a SharedSeq[T]. No explicit dealloc is required
  ## as req[T] is a GC managed type.
  var ret = newSeq[T]()
  for i in 0 ..< s.len:
    ret.add(s.data[i])
  return ret

proc allocSharedSeqFromCArray*[T](arr: ptr T, len: int): SharedSeq[T] =
  ## Creates a SharedSeq[T] from a C array pointer and length.
  ## The data is copied to shared memory.
  ## There should be a corresponding manual deallocation with deallocSharedSeq!
  if arr.isNil() or len <= 0:
    return (nil, 0)

  when T is cstring:
    # Special handling for arrays of cstrings
    let data = cast[ptr UncheckedArray[cstring]](allocShared(sizeof(cstring) * len))
    let cstrArr = cast[ptr UncheckedArray[cstring]](arr)

    for i in 0 ..< len:
      # Use the existing alloc proc to properly allocate each cstring
      data[i] = cstrArr[i].alloc()

    return (data, len)
  else:
    # Original handling for non-cstring types
    let data = allocShared(sizeof(T) * len)
    copyMem(data, arr, sizeof(T) * len)
    return (cast[ptr UncheckedArray[T]](data), len)

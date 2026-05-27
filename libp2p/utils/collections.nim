# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sets

proc capLen*[T](s: var seq[T], length: Natural) =
  if s.len > length:
    s.setLen(length)

template exclIfIt*[T](set: var HashSet[T], condition: untyped) =
  if set.len != 0:
    var toExcl = HashSet[T]()
    for it {.inject.} in set:
      if condition:
        toExcl.incl(it)
    set.excl(toExcl)

template filterIt*[T](set: HashSet[T], condition: untyped): HashSet[T] =
  var filtered = HashSet[T]()
  if set.len != 0:
    for it {.inject.} in set:
      if condition:
        filtered.incl(it)
  filtered

proc toChunks*[T](data: seq[T], size: int): seq[seq[T]] {.raises: [].} =
  ## Splits `data` into chunks of length `size`.
  ## The last chunk may be smaller if data.len is not divisible by size.
  if size <= 0:
    return @[]

  var res: seq[seq[T]] = @[]
  var i = 0
  while i < data.len:
    let endIndex = min(i + size, data.len)
    res.add(data[i ..< endIndex])
    i = endIndex
  return res

proc take*[T](s: seq[T], n: int): seq[T] =
  ## Take first `n` elements of `s`, or `s.len()` if `n > s.len()`
  let count = min(s.len, max(n, 0))
  if count == 0:
    return @[]
  return s[0 .. count - 1]

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import algorithm

proc unorderedCompare*[T](a, b: seq[T]): bool =
  if a == b:
    return true
  if a.len != b.len:
    return false

  var aSorted = a
  var bSorted = b
  aSorted.sort()
  bSorted.sort()

  return aSorted == bSorted

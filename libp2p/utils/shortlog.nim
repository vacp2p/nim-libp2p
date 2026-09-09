# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import stew/byteutils

const ShortDumpMax = 12
const ShortCollectionMax* = 5

func shortLog*(item: seq[byte]): string =
  if item.len <= ShortDumpMax:
    item.toHex()
  else:
    const
      split = ShortDumpMax div 2
      dumpLen = (ShortDumpMax * 2) + 3
    var s = newStringOfCap(dumpLen)
    s &= item.toOpenArray(0, split - 1).toHex()
    s &= "..."
    s &= item.toOpenArray(item.len - split, item.high).toHex()
    s

func shortLog*(item: openArray[byte]): string =
  if item.len <= ShortDumpMax:
    item.toHex()
  else:
    const
      split = ShortDumpMax div 2
      dumpLen = (ShortDumpMax * 2) + 3
    var s = newStringOfCap(dumpLen)
    s &= item.toOpenArray(0, split - 1).toHex()
    s &= "..."
    s &= item.toOpenArray(item.len - split, item.high).toHex()
    s

func shortLog*(item: string): string =
  if item.len <= ShortDumpMax:
    item
  else:
    const
      split = ShortDumpMax div 2
      dumpLen = ShortDumpMax + 3
    var s = newStringOfCap(dumpLen)
    s &= item[0 ..< split]
    s &= "..."
    s &= item[(item.len - split) .. item.high]
    s

func shortLog*[T](items: openArray[T], maxItems = ShortCollectionMax): string =
  ## Render a bounded collection preview without falling back to an unbounded
  ## ``$items`` representation. Elements with their own ``shortLog`` overload
  ## retain a useful preview.
  let limit = min(items.len, maxItems)
  var res = newStringOfCap(limit * ShortDumpMax)
  res.add('[')
  for i in 0 ..< limit:
    if i > 0:
      res.add(", ")
    when compiles(shortLog(items[i])):
      res.add($shortLog(items[i]))
    else:
      res.add($items[i])
  res.add(']')
  if items.len > maxItems:
    res.add("...(+")
    res.add($(items.len - maxItems))
    res.add(" more)")
  res

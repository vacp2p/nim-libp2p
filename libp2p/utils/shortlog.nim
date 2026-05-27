# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import stew/byteutils

const ShortDumpMax = 12

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

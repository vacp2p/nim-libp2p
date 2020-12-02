## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import stew/byteutils

const
  ShortDumpMax = 12

func shortLog*(item: openarray[byte]): string =
  if item.len <= ShortDumpMax:
    result = item.toHex()
  else:
    const
      split = ShortDumpMax div 2
      dumpLen = (ShortDumpMax * 2) + 3
    result = newStringOfCap(dumpLen)
    result &= item.toOpenArray(0, split - 1).toHex()
    result &= "..."
    result &= item.toOpenArray(item.len - split, item.high).toHex()

func shortLog*(item: string): string =
  if item.len <= ShortDumpMax:
    result = item
  else:
    const
      split = ShortDumpMax div 2
      dumpLen = ShortDumpMax + 3
    result = newStringOfCap(dumpLen)
    result &= item[0..<split]
    result &= "..."
    result &= item[(item.len - split)..item.high]

when defined(internal_testing):
  import tables

  var
    Counters = initTable[string, int64]()

  template incDebugCounter*(item: string, increase: auto = 1) =
    {.gcsafe.}: # this is a lie but threading is also a lie in this context
      let current = Counters.getOrDefault(item)
      Counters[item] = current + increase
  
  template decDebugCounter*(item: string, increase: auto = 1) =
    {.gcsafe.}: # this is a lie but threading is also a lie in this context
      let current = Counters.getOrDefault(item)
      Counters[item] = current - increase

  template getDebugCounter*(item: string): int64 = 
    {.gcsafe.}: # this is a lie but threading is also a lie in this context
      Counters.getOrDefault(item)
  
  template resetDebugCounter*(item: string) =
    {.gcsafe.}: # this is a lie but threading is also a lie in this context
      if Counters.contains(item):
        Counters[item].clear()
else:
  template incDebugCounter*(item: string, increase: auto = 1) = discard
  template decDebugCounter*(item: string, increase: auto = 1) = discard
  template getDebugCounter*(item: string): int64 = 0
  template resetDebugCounter*(item: string) = discard

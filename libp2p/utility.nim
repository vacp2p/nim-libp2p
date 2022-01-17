## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import stew/byteutils

const
  ShortDumpMax = 12

func shortLog*(item: openArray[byte]): string =
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

when defined(libp2p_agents_metrics):
  import strutils
  export split

  import stew/results
  export results

  proc safeToLowerAscii*(s: string): Result[string, cstring] =
    try:
      ok(s.toLowerAscii())
    except CatchableError:
      err("toLowerAscii failed")

  const
    KnownLibP2PAgents* {.strdefine.} = ""
    KnownLibP2PAgentsSeq* = KnownLibP2PAgents.safeToLowerAscii().tryGet().split(",")

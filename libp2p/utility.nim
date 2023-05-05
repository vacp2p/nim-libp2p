# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import stew/byteutils

template public* {.pragma.}

const
  ShortDumpMax = 12

template compilesOr*(a, b: untyped): untyped =
  when compiles(a):
    a
  else:
    b

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
    KnownLibP2PAgents* {.strdefine.} = "nim-libp2p"
    KnownLibP2PAgentsSeq* = KnownLibP2PAgents.safeToLowerAscii().tryGet().split(",")

template safeConvert*[T: SomeInteger, S: Ordinal](value: S): T =
  ## Converts `value` from S to `T` iff `value` is guaranteed to be preserved.
  when int64(T.low) <= int64(S.low()) and uint64(T.high) >= uint64(S.high):
    T(value)
  else:
    {.error: "Source and target types have an incompatible range low..high".}

template exceptionToAssert*(body: untyped): untyped =
  block:
    var res: type(body)
    when defined(nimHasWarnBareExcept):
      {.push warning[BareExcept]:off.}
    try:
      res = body
    except CatchableError as exc: raise exc
    except Defect as exc: raise exc
    except Exception as exc: raiseAssert exc.msg
    when defined(nimHasWarnBareExcept):
      {.pop.}
    res

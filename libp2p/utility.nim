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
import chronos, chronicles

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

template awaitrc*[T](f: Future[T]): untyped =
  const AttemptsCount = 2
  when declared(chronosInternalRetFuture):
    when not declaredInScope(chronosInternalTmpFuture):
      var chronosInternalTmpFuture {.inject.}: FutureBase
    var fut =
      block:
        var res: type(f)
        for i in 0 ..< AttemptsCount:
          chronosInternalTmpFuture = f
          chronosInternalRetFuture.child = chronosInternalTmpFuture
          yield chronosInternalTmpFuture
          chronosInternalRetFuture.child = nil
          res = cast[type(f)](chronosInternalTmpFuture)
          case res.state
          of FutureState.Pending:
            raiseAssert("yield returns pending Future")
          of FutureState.Finished:
            break
          of FutureState.Failed:
            if not(res.error of CancelledError):
              break
          of FutureState.Cancelled:
            continue
        res
    fut.internalCheckComplete()
    when T isnot void:
      cast[type(f)](fut).internalRead()
  else:
    unsupported "awaitrc is only available within {.async.}"

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

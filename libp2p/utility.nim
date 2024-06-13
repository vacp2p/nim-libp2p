# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[sets, options, macros]
import stew/[byteutils, results]

export results

template public*() {.pragma.}

const ShortDumpMax = 12

template compilesOr*(a, b: untyped): untyped =
  when compiles(a): a else: b

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
    result &= item[0 ..< split]
    result &= "..."
    result &= item[(item.len - split) .. item.high]

when defined(libp2p_agents_metrics):
  import strutils
  export split

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

proc capLen*[T](s: var seq[T], length: Natural) =
  if s.len > length:
    s.setLen(length)

template exceptionToAssert*(body: untyped): untyped =
  block:
    var res: type(body)
    when defined(nimHasWarnBareExcept):
      {.push warning[BareExcept]: off.}
    try:
      res = body
    except CatchableError as exc:
      raise exc
    except Defect as exc:
      raise exc
    except Exception as exc:
      raiseAssert exc.msg
    when defined(nimHasWarnBareExcept):
      {.pop.}
    res

template withValue*[T](self: Opt[T] | Option[T], value, body: untyped): untyped =
  ## This template provides a convenient way to work with `Option` types in Nim.
  ## It allows you to execute a block of code (`body`) only when the `Option` is not empty.
  ##
  ## `self` is the `Option` instance being checked.
  ## `value` is the variable name to be used within the `body` for the unwrapped value.
  ## `body` is a block of code that is executed only if `self` contains a value.
  ##
  ## The `value` within `body` is automatically unwrapped from the `Option`, making it
  ## simpler to work with without needing explicit checks or unwrapping.
  ##
  ## Example:
  ## ```nim
  ## let myOpt = Opt.some(5)
  ## myOpt.withValue(value):
  ##   echo value # Will print 5
  ## ```
  ##
  ## Note: This is a template, and it will be inlined at the call site, offering good performance.
  let temp = (self)
  if temp.isSome:
    let value {.inject.} = temp.get()
    body

template withValue*[T, E](self: Result[T, E], value, body: untyped): untyped =
  self.toOpt().withValue(value, body)

macro withValue*[T](self: Opt[T] | Option[T], value, body, elseStmt: untyped): untyped =
  let elseBody = elseStmt[0]
  quote:
    let temp = (`self`)
    if temp.isSome:
      let `value` {.inject.} = temp.get()
      `body`
    else:
      `elseBody`

template valueOr*[T](self: Option[T], body: untyped): untyped =
  let temp = (self)
  if temp.isSome:
    temp.get()
  else:
    body

template toOpt*[T, E](self: Result[T, E]): Opt[T] =
  let temp = (self)
  if temp.isOk:
    when T is void:
      Result[void, void].ok()
    else:
      Opt.some(temp.unsafeGet())
  else:
    Opt.none(type(T))

template exclIfIt*[T](set: var HashSet[T], condition: untyped) =
  if set.len != 0:
    var toExcl = HashSet[T]()
    for it {.inject.} in set:
      if condition:
        toExcl.incl(it)
    set.excl(toExcl)

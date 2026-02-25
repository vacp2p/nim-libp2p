# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import std/[sets, options, macros]
import stew/byteutils
import results, chronos, sequtils

export results

## public pragma is marker of "public" api subject to stronger stability guarantees.
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
    except CatchableError as e:
      let errMsg = "toLowerAscii failed: " & e.msg
      err(errMsg.cstring)

  const
    KnownLibP2PAgents* {.strdefine.} = "nim-libp2p"
    KnownLibP2PAgentsSeq* = KnownLibP2PAgents.safeToLowerAscii().tryGet().split(",")

proc safeConvert*[T: SomeInteger](value: SomeOrdinal): T =
  type S = typeof(value)
  ## Converts `value` from S to `T` iff `value` is guaranteed to be preserved.
  when int64(T.low) <= int64(S.low()) and uint64(T.high) >= uint64(S.high):
    T(value)
  else:
    {.error: "Source and target types have an incompatible range low..high".}

proc capLen*[T](s: var seq[T], length: Natural) =
  if s.len > length:
    s.setLen(length)

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

template filterIt*[T](set: HashSet[T], condition: untyped): HashSet[T] =
  var filtered = HashSet[T]()
  if set.len != 0:
    for it {.inject.} in set:
      if condition:
        filtered.incl(it)
  filtered

macro includeFile*(file: static[string]): untyped =
  let res = newStmtList()

  try:
    res.add(nnkIncludeStmt.newTree(newLit(file)))
  except ValueError as e:
    raiseAssert("Failed to include file: " & file & ", error: " & e.msg)

  return res

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

proc collectCompleted*[T, E](
    futs: seq[InternalRaisesFuture[T, E]], timeout: chronos.Duration
): Future[seq[T]] {.async: (raises: [CancelledError]).} =
  ## Wait up to `timeout`; collect only successfully completed futures.
  ## Ignore results from futures throwing errors
  try:
    await futs.allFutures().wait(timeout)
  except AsyncTimeoutError:
    # Some futures didn’t finish in time, ignore
    discard

  # Collect only successful results
  return futs.filterIt(it.completed()).mapIt(it.value())

proc take*[T](s: seq[T], n: int): seq[T] =
  ## Take first `n` elements of `s`, or `s.len()` if `n > s.len()`
  let count = min(s.len, max(n, 0))
  if count == 0:
    return @[]
  return s[0 .. count - 1]

proc waitForTCPServer*(
    taddr: TransportAddress,
    retries: int = 20,
    delay: chronos.Duration = 500.milliseconds,
): Future[bool] {.async.} =
  for i in 0 ..< retries:
    try:
      let conn = await connect(taddr)
      await conn.closeWait()
      return true
    except OSError:
      discard
    except TransportOsError:
      discard
    await sleepAsync(delay)
  return false

proc toOpt*[T: ref object](x: T): Opt[T] {.inline.} =
  if x.isNil:
    Opt.none(T)
  else:
    Opt.some(x)

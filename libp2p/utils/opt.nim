# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/macros
import results

export results

func toOpt*[T](v: Opt[T] | T): Opt[T] =
  when v is T:
    Opt.some(v)
  else:
    v

template toOpt*[T, E](self: Result[T, E]): Opt[T] =
  let temp = (self)
  if temp.isOk:
    when T is void:
      Result[void, void].ok()
    else:
      Opt.some(temp.unsafeGet())
  else:
    Opt.none(type(T))

proc toOpt*[T: ref object](x: T): Opt[T] {.inline.} =
  if x.isNil:
    Opt.none(T)
  else:
    Opt.some(x)

template withValue*[T](self: Opt[T], value, body: untyped): untyped =
  ## This template provides a convenient way to work with `Opt` types in Nim.
  ## It allows you to execute a block of code (`body`) only when the `Opt` is not empty.
  ##
  ## `self` is the `Opt` instance being checked.
  ## `value` is the variable name to be used within the `body` for the unwrapped value.
  ## `body` is a block of code that is executed only if `self` contains a value.
  ##
  ## The `value` within `body` is automatically unwrapped from the `Opt`, making it
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
    let value {.inject, used.} = temp.get()
    body

template withValue*[T, E](self: Result[T, E], value, body: untyped): untyped =
  self.toOpt().withValue(value, body)

macro withValue*[T](self: Opt[T], value, body, elseStmt: untyped): untyped =
  let elseBody = elseStmt[0]
  quote:
    let temp = (`self`)
    if temp.isSome:
      let `value` {.inject, used.} = temp.get()
      `body`
    else:
      `elseBody`

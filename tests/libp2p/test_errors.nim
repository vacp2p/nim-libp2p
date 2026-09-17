# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results
import ../../libp2p/errors
import ../tools/unittest

type
  DemoErrorKind = enum
    Malformed

  DemoError = object of LPError

suite "Errors":
  test "toException carries the formatted error":
    let e = Malformed.toException(DemoError)
    check:
      e of ref DemoError
      e.msg == "Malformed"

  test "valueOrRaise returns the value":
    let r = Result[int, string].ok(7)
    check r.valueOrRaise(DemoError) == 7

  test "valueOrRaise raises the requested exception with the message":
    let r = Result[int, string].err("bad address")
    try:
      discard r.valueOrRaise(DemoError)
      raiseAssert "should not get here"
    except DemoError as e:
      check e.msg == "bad address"

  test "valueOrRaise evaluates its argument once":
    var calls = 0

    proc make(): Result[int, string] =
      inc calls
      Result[int, string].ok(1)

    discard make().valueOrRaise(DemoError)
    check calls == 1

  test "onErrorRaise passes an ok result":
    Result[void, cstring].ok().onErrorRaise(DemoError)

  test "onErrorRaise raises the requested exception with the message":
    let r = Result[void, cstring].err("invalid parameters")
    try:
      r.onErrorRaise(DemoError)
      raiseAssert "should not get here"
    except DemoError as e:
      check e.msg == "invalid parameters"

  test "onErrorRaise evaluates its argument once":
    var calls = 0

    proc make(): Result[void, string] =
      inc calls
      Result[void, string].ok()

    make().onErrorRaise(DemoError)
    check calls == 1

  test "each template can be called twice in the same scope":
    let
      a = Result[int, string].ok(1).valueOrRaise(DemoError)
      b = Result[int, string].ok(2).valueOrRaise(DemoError)
    Result[void, string].ok().onErrorRaise(DemoError)
    Result[void, string].ok().onErrorRaise(DemoError)
    check a + b == 3

  test "each template accepts only its kind of result":
    check:
      not compiles(Result[void, string].ok().valueOrRaise(DemoError))
      not compiles(Result[int, string].ok(1).onErrorRaise(DemoError))

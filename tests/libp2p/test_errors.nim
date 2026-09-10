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

  test "raiseOr returns the value":
    let r = Result[int, string].ok(7)
    check r.raiseOr(DemoError) == 7

  test "raiseOr raises the requested exception with the message":
    let r = Result[int, string].err("bad address")
    try:
      discard r.raiseOr(DemoError)
      check false
    except DemoError as e:
      check e.msg == "bad address"

  test "raiseOr evaluates its argument once":
    var calls = 0

    proc make(): Result[int, string] =
      inc calls
      Result[int, string].ok(1)

    discard make().raiseOr(DemoError)
    check calls == 1

  test "raiseOr accepts a void result":
    let ok = Result[void, cstring].ok()
    ok.raiseOr(DemoError)

    let bad = Result[void, cstring].err("invalid parameters")
    try:
      bad.raiseOr(DemoError)
      check false
    except DemoError as e:
      check e.msg == "invalid parameters"

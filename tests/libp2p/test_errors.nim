# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results
import ../../libp2p/errors
import ../tools/unittest

type
  DemoErrorKind = enum
    Malformed
    Unsupported

  DemoError = object of LPError

suite "Errors":
  test "$ shows the kind alone when there is no message":
    check $lpError(Malformed) == "Malformed"

  test "$ shows kind and message":
    check $lpError(Unsupported, "quic") == "Unsupported: quic"

  test "toException carries the formatted error":
    let e = lpError(Malformed, "short header").toException(DemoError)
    check:
      e of ref DemoError
      e.msg == "Malformed: short header"

  test "raiseOr returns the value":
    let r = LPResult[int, DemoErrorKind].ok(7)
    check r.raiseOr(DemoError) == 7

  test "raiseOr raises the requested exception with the message":
    let r = LPResult[int, DemoErrorKind].err(lpError(Unsupported, "onion"))
    try:
      discard r.raiseOr(DemoError)
      check false
    except DemoError as e:
      check e.msg == "Unsupported: onion"

  test "raiseOr evaluates its argument once":
    var calls = 0

    proc make(): LPResult[int, DemoErrorKind] =
      inc calls
      LPResult[int, DemoErrorKind].ok(1)

    discard make().raiseOr(DemoError)
    check calls == 1

  test "raiseOr accepts a void result":
    let ok = LPResult[void, DemoErrorKind].ok()
    ok.raiseOr(DemoError)

    let bad = LPResult[void, DemoErrorKind].err(lpError(Malformed))
    expect DemoError:
      bad.raiseOr(DemoError)

  test "raiseOr accepts a string error":
    let r = Result[int, string].err("bad address")
    try:
      discard r.raiseOr(DemoError)
      check false
    except DemoError as e:
      check e.msg == "bad address"

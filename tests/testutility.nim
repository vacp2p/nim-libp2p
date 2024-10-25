#!fmt: off Disable formatting for this file https://github.com/arnetheduck/nph/issues/69
{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options
import ./helpers
import ../libp2p/utility

suite "Utility":

  test "successful safeConvert from int8 to int16":
    let res = safeConvert[int16]((-128).int8)
    check res == -128'i16

  test "unsuccessful safeConvert from int16 to int8":
    check not (compiles do:
      result: int8 = safeConvert[int8](32767'i16))

  test "successful safeConvert from uint8 to uint16":
    let res: uint16 = safeConvert[uint16](255'u8)
    check res == 255'u16

  test "unsuccessful safeConvert from uint16 to uint8":
    check not (compiles do:
      result: uint8 = safeConvert[uint8](256'u16))

  test "unsuccessful safeConvert from int to char":
    check not (compiles do:
      result: char = safeConvert[char](128))

  test "successful safeConvert from bool to int":
    let res: int = safeConvert[int](true)
    check res == 1

  test "unsuccessful safeConvert from int to bool":
    check not (compiles do:
      result: bool = safeConvert[bool](2))

  test "successful safeConvert from enum to int":
    type Color = enum red, green, blue
    let res: int = safeConvert[int](green)
    check res == 1

  test "unsuccessful safeConvert from int to enum":
    type Color = enum red, green, blue
    check not (compiles do:
      result: Color = safeConvert[Color](3))

  test "successful safeConvert from range to int":
    let res: int = safeConvert[int, range[1..10]](5)
    check res == 5

  test "unsuccessful safeConvert from int to range":
    check not (compiles do:
      result: range[1..10] = safeConvert[range[1..10], int](11))

  test "unsuccessful safeConvert from int to uint":
    check not (compiles do:
      result: uint = safeConvert[uint](11))

  test "unsuccessful safeConvert from uint to int":
    check not (compiles do:
      result: uint = safeConvert[int](11.uint))

suite "withValue and valueOr templates":
  type
    TestObj = ref object
      x: int

  proc objIncAndOpt(self: TestObj): Opt[TestObj] =
    self.x.inc()
    return Opt.some(self)

  proc objIncAndOption(self: TestObj): Option[TestObj] =
    self.x.inc()
    return some(self)

  test "withValue calls right branch when Opt/Option is none":
    var counter = 0
    # check Opt/Option withValue with else
    Opt.none(TestObj).withValue(v):
      fail()
    else:
      counter.inc()
    none(TestObj).withValue(v):
      fail()
    else:
      counter.inc()
    check counter == 2

    # check Opt/Option withValue without else
    Opt.none(TestObj).withValue(v):
      fail()
    none(TestObj).withValue(v):
      fail()

  test "withValue calls right branch when Opt/Option is some":
    var counter = 1
    # check Opt/Option withValue with else
    Opt.some(counter).withValue(v):
      counter.inc(v)
    else:
      fail()
    some(counter).withValue(v):
      counter.inc(v)
    else:
      fail()

    # check Opt/Option withValue without else
    Opt.some(counter).withValue(v):
      counter.inc(v)
    some(counter).withValue(v):
      counter.inc(v)
    check counter == 16

  test "withValue calls right branch when Opt/Option is some with proc call":
    var obj = TestObj(x: 0)
    # check Opt/Option withValue with else
    objIncAndOpt(obj).withValue(v):
      v.x.inc()
    else:
      fail()
    objIncAndOption(obj).withValue(v):
      v.x.inc()
    else:
      fail()

    # check Opt/Option withValue without else
    objIncAndOpt(obj).withValue(v):
      v.x.inc()
    objIncAndOption(obj).withValue(v):
      v.x.inc()

    check obj.x == 8

  test "valueOr calls with and without proc call":
    var obj = none(TestObj).valueOr:
      TestObj(x: 0)
    check obj.x == 0
    obj = some(TestObj(x: 2)).valueOr:
      fail()
      return
    check obj.x == 2

    obj = objIncAndOpt(obj).valueOr:
      fail()
      return
    check obj.x == 3

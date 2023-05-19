{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import strformat
import ./helpers
import ../libp2p/utility

suite "Utility":

  test "successful safeConvert from int8 to int16":
    let res = safeConvert[int16, int8]((-128).int8)
    check res == -128'i16

  test "unsuccessful safeConvert from int16 to int8":
    check not (compiles do:
      result: int8 = safeConvert[int8, int16](32767'i16))

  test "successful safeConvert from uint8 to uint16":
    let res: uint16 = safeConvert[uint16, uint8](255'u8)
    check res == 255'u16

  test "unsuccessful safeConvert from uint16 to uint8":
    check not (compiles do:
      result: uint8 = safeConvert[uint8, uint16](256'u16))

  test "successful safeConvert from char to int":
    let res: int = safeConvert[int, char]('A')
    check res == 65

  test "unsuccessful safeConvert from int to char":
    check not (compiles do:
      result: char = safeConvert[char, int](128))

  test "successful safeConvert from bool to int":
    let res: int = safeConvert[int, bool](true)
    check res == 1

  test "unsuccessful safeConvert from int to bool":
    check not (compiles do:
      result: bool = safeConvert[bool, int](2))

  test "successful safeConvert from enum to int":
    type Color = enum red, green, blue
    let res: int = safeConvert[int, Color](green)
    check res == 1

  test "unsuccessful safeConvert from int to enum":
    type Color = enum red, green, blue
    check not (compiles do:
      result: Color = safeConvert[Color, int](3))

  test "successful safeConvert from range to int":
    let res: int = safeConvert[int, range[1..10]](5)
    check res == 5

  test "unsuccessful safeConvert from int to range":
    check not (compiles do:
      result: range[1..10] = safeConvert[range[1..10], int](11))

  test "unsuccessful safeConvert from int to uint":
    check not (compiles do:
      result: uint = safeConvert[uint, int](11))

  test "unsuccessful safeConvert from uint to int":
    check not (compiles do:
      result: uint = safeConvert[int, uint](11.uint))

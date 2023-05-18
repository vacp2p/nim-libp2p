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
    var result: int16 = safeConvert[int16, int8](-128)
    assert result == -128, fmt"Expected -128 but got {result}"

  test "unsuccessful safeConvert from int16 to int8":
    doAssert not (compiles do:
      var result: int8 = safeConvert[int8, int16](32767))

  test "successful safeConvert from uint8 to uint16":
    var result: uint16 = safeConvert[uint16, uint8](255)
    assert result == 255, fmt"Expected 255 but got {result}"

  test "unsuccessful safeConvert from uint16 to uint8":
    doAssert not (compiles do:
      var result: uint8 = safeConvert[uint8, uint16](256))

  test "successful safeConvert from char to int":
    var result: int = safeConvert[int, char]('A')
    assert result == 65, fmt"Expected 65 but got {result}"

  test "unsuccessful safeConvert from int to char":
    doAssert not (compiles do:
      var result: char = safeConvert[char, int](128))

  test "successful safeConvert from bool to int":
    var result: int = safeConvert[int, bool](true)
    assert result == 1, fmt"Expected 1 but got {result}"

  test "unsuccessful safeConvert from int to bool":
    doAssert not (compiles do:
      var result: bool = safeConvert[bool, int](2))

  test "successful safeConvert from enum to int":
    type Color = enum red, green, blue
    var result: int = safeConvert[int, Color](green)
    assert result == 1, fmt"Expected 1 but got {result}"

  test "unsuccessful safeConvert from int to enum":
    type Color = enum red, green, blue
    doAssert not (compiles do:
      var result: Color = safeConvert[Color, int](3))

  test "successful safeConvert from range to int":
    var result: int = safeConvert[int, range[1..10]](5)
    assert result == 5, fmt"Expected 5 but got {result}"

  test "unsuccessful safeConvert from int to range":
    doAssert not (compiles do:
      var result: range[1..10] = safeConvert[range[1..10], int](11))

  test "unsuccessful safeConvert from int to uint":
    doAssert not (compiles do:
      var result: uint = safeConvert[uint, int](11))

  test "unsuccessful safeConvert from uint to int":
    doAssert not (compiles do:
      var result: uint = safeConvert[int, uint](11))



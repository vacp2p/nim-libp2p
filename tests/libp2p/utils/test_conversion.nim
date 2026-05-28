# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/utils/conversion
import ../../tools/[unittest]

suite "Conversion":
  test "successful safeConvert from int8 to int16":
    let res = safeConvert[int16]((-128).int8)
    check res == -128'i16

  test "unsuccessful safeConvert from int16 to int8":
    check not (compiles do:
      let converted: int8 = safeConvert[int8](32767'i16))

  test "successful safeConvert from uint8 to uint16":
    let res: uint16 = safeConvert[uint16](255'u8)
    check res == 255'u16

  test "unsuccessful safeConvert from uint16 to uint8":
    check not (compiles do:
      let converted: uint8 = safeConvert[uint8](256'u16))

  test "unsuccessful safeConvert from int to char":
    check not (compiles do:
      let converted: char = safeConvert[char](128))

  test "successful safeConvert from bool to int":
    let res: int = safeConvert[int](true)
    check res == 1

  test "unsuccessful safeConvert from int to bool":
    check not (compiles do:
      let converted: bool = safeConvert[bool](2))

  test "successful safeConvert from enum to int":
    type Color = enum
      red
      green
      blue

    let res: int = safeConvert[int](green)
    check res == 1

  test "unsuccessful safeConvert from int to enum":
    type Color = enum
      red
      green
      blue

    check not (compiles do:
      let converted: Color = safeConvert[Color](3))

  test "unsuccessful safeConvert from int to uint":
    check not (compiles do:
      let converted: uint = safeConvert[uint](11))

  test "unsuccessful safeConvert from uint to int":
    check not (compiles do:
      let converted: uint = safeConvert[int](11.uint))

  test "ipv4ToString renders dotted-decimal IPv4":
    check ipv4ToString([1'u8, 2, 3, 4]) == "1.2.3.4"
    check ipv4ToString([0'u8, 0, 0, 0]) == "0.0.0.0"
    check ipv4ToString([255'u8, 255, 255, 255]) == "255.255.255.255"

  test "ipv4ToString rejects wrong length":
    expect ValueError:
      discard ipv4ToString([1'u8, 2, 3])
    expect ValueError:
      discard ipv4ToString([1'u8, 2, 3, 4, 5])

  test "ipv6ToString renders compressed IPv6":
    check ipv6ToString(
      [0x26'u8, 0x06, 0x47, 0x00, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0x68, 0x16, 0x19, 0xb5]
    ) == "2606:4700:10::6816:19b5"
    check ipv6ToString([0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]) == "::1"
    check ipv6ToString([0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) == "::"

  test "ipv6ToString rejects wrong length":
    expect ValueError:
      discard ipv6ToString([0'u8, 0, 0, 0])
    expect ValueError:
      discard ipv6ToString(newSeq[byte](17))

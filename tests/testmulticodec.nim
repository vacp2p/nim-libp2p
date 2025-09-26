{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import ../libp2p/multicodec
import ../libp2p/utils/sequninit

suite "multicodecs":

  # register once for entire module (at compile time)
  registerMultiCodecs:
    ("codec1", 0x101)
    ("codec2", 0x102)
    ("codec3", 0x103)

  test "can assign registered codecs by name":
    check:
      compiles:
        const codec1 = multiCodec("codec1")
        const codec2 = multiCodec("codec2")
        const codec3 = multiCodec("codec3")

  test "can assign registered codecs by code":
    check:
      compiles:
        const codec1x = multiCodec(0x101)
        const codec2x = multiCodec(0x102)
        const codec3x = multiCodec(0x103)

  test "registered codecs have correct codes at compile time":
    check:
      multiCodec("codec1") == 0x101
      multiCodec("codec2") == 0x102
      multiCodec("codec3") == 0x103

  test "registered codecs have correct names at compile time":
    check:
      multiCodec(0x101) == multiCodec("codec1")
      multiCodec(0x102) == multiCodec("codec2")
      multiCodec(0x103) == multiCodec("codec3")

  test "registered codecs have correct codes at runtime":
    check:
      MultiCodec.codec("codec1") == 0x101
      MultiCodec.codec("codec2") == 0x102
      MultiCodec.codec("codec3") == 0x103

  test "registered codecs have correct names at runtime":
    check:
      MultiCodec.codec(0x101) == MultiCodec.codec("codec1")
      MultiCodec.codec(0x102) == MultiCodec.codec("codec2")
      MultiCodec.codec(0x103) == MultiCodec.codec("codec3")

  test "registered codecs are the same at compile time and runtime":
    check:
      MultiCodec.codec(0x101) == multiCodec(0x101)
      MultiCodec.codec(0x102) == multiCodec(0x102)
      MultiCodec.codec(0x103) == multiCodec(0x103)

  test "registered codecs are the same at compile time and runtime":
    check:
      MultiCodec.codec("codec1") == multiCodec("codec1")
      MultiCodec.codec("codec2") == multiCodec("codec2")
      MultiCodec.codec("codec3") == multiCodec("codec3")

  test "referencing unregistered codecs by name does not compile":
      check:
        not compiles(
          multiCodec("codecX")
        )

  test "referencing unregistered codecs by code does not compile":
    check:
      not compiles(
        multiCodec(0x9999)
      )

  test "cannot register codec with already registered name":
    check:
      # Should fail to compile with
      # Error: Codec name 'codec1' is already registered
      not compiles(block:
        registerMultiCodecs:
          ("codec1", 0x201)
      )

  test "cannot register codec with already registered code":
    check:
      # Should fail to compile with
      # Error: Codec code 0x0101 is already registered
      not compiles(block:
        registerMultiCodecs:
          ("codecX", 0x101)
      )

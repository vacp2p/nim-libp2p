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
import ../../libp2p/multibase
import stew/byteutils
import results

suite "MutliBase extensions":
  test "extended hashes correctly hash data":
    var enc = newString(6)
    var dec = newSeq[byte](1)
    var msg = "x".toBytes
    var olen: int

    check:
      MultiBase.encode("codec_mb1", msg).get() == "$ext_x"
      MultiBase.encode("codec_mb1", msg, enc, olen) == MultiBaseStatus.Success
      enc == "$ext_x"
      olen == 6

      MultiBase.decode("$ext_x").get().len == 1
      MultiBase.decode("$ext_x", dec, olen) == MultiBaseStatus.Success
      string.fromBytes(dec) == "x"
      olen == 1

  test "can override codec functions of default multibase codec":
    var enc = newString(6)
    var dec = newSeq[byte](1)
    var msg = "x".toBytes
    var olen: int

    check:
      # the default identity encoding would be "\x00"
      MultiBase.encode("identity", msg).get() == "\x00ext_x"
      MultiBase.encode("identity", msg, enc, olen) == MultiBaseStatus.Success
      enc == "\x00ext_x"
      olen == 6

      MultiBase.decode("\x00ext_x").get().len == 1
      MultiBase.decode("\x00ext_x", dec, olen) == MultiBaseStatus.Success
      string.fromBytes(dec) == "x"
      olen == 1

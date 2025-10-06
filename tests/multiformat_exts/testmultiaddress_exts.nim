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
import ../../libp2p/multicodec
import ../../libp2p/multiaddress
import ../../libp2p/transcoder

suite "MutliAddress extensions":
  test "registered protocols can be correctly initialized":
    let maInit = MultiAddress.init("/codec_mc1/test").get()

    check $maInit == "/codec_mc1/test"

  test "can register an overriding protocol for already registered protocol":
    let maInit = MultiAddress.init("/ip4/test").get()

    check $maInit == "/ip4/test"

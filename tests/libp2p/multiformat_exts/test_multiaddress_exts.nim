# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import ../../../libp2p/[multicodec, multiaddress, transcoder]
import ../../tools/unittest

suite "MutliAddress extensions":
  test "registered protocols can be correctly initialized":
    let maInit = MultiAddress.init("/codec_mc1/test").get()

    check $maInit == "/codec_mc1/test"

  test "can register an overriding protocol for already registered protocol":
    let maInit = MultiAddress.init("/ip4/test").get()

    check $maInit == "/ip4/test"

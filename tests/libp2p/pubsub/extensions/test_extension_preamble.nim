# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub/extension_preamble, gossipsub/extensions_types, rpc/messages]
import ../../../tools/[unittest, crypto]

suite "GossipSub Extensions :: Preamble Extension":
  let peerId = PeerId.random(rng).get()

  test "isSupported":
    let ext = PreambleExtension.new()
    check:
      ext.isSupported(PeerExtensions()) == false
      ext.isSupported(PeerExtensions(preambleExtension: true)) == true

  test "config validation":
    expect AssertionDefect:
      discard PreambleExtension.new(PreambleExtensionConfig(maxPreamblePeerBudget: 0))
    expect AssertionDefect:
      discard PreambleExtension.new(PreambleExtensionConfig(maxHeIsReceiving: 0))

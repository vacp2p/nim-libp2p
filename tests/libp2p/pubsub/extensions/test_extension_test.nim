# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub/extension_test, gossipsub/extensions_types]
import ../../../tools/[unittest, crypto]
import ../utils

suite "GossipSub Extensions :: Test Extension":
  let peerId = PeerId.random(rng).get()

  test "basic test":
    var (negotiatedPeers, onNegotiatedCb) = createCollectPeerCallback()
    let ext = TestExtension.new(TestExtensionConfig(onNegotiated: onNegotiatedCb))

    check:
      ext.isSupported(PeerExtensions()) == false
      ext.isSupported(PeerExtensions(testExtension: true)) == true

    ext.onNegotiated(peerId)
    check:
      negotiatedPeers[] == @[peerId]

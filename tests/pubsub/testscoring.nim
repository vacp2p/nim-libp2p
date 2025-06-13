# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable, pubsubpeer]
import ../../libp2p/muxers/muxer
import ../helpers

suite "GossipSub Scoring":
  teardown:
    checkTrackers()

  asyncTest "Disconnect bad peers":
    let topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(30, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.parameters.appSpecificWeight = 1.0

    for i, peer in peers:
      peer.appScore = gossipSub.parameters.graylistThreshold - 1
      let conn = conns[i]
      gossipSub.switch.connManager.storeMuxer(Muxer(connection: conn))

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

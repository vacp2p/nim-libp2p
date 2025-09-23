{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import options, chronos, sets
import
  ../../libp2p/[
    protocols/rendezvous,
    switch,
    builders,
    discovery/discoverymngr,
    discovery/rendezvousinterface,
  ]
import ../helpers
import ../utils/async_tests
import ./utils

suite "Discovery Manager":
  teardown:
    checkTrackers()

  asyncTest "RendezVous - advertise and request":
    const namespace = "foo"

    # Setup: [0] ClientA, [1] ClientB, [2] RemoteNode
    let (dms, nodes) = setupDiscMngrNodes(3)
    nodes.startAndDeferStop()
    dms.deferStop()

    # Topology: ClientA <==> RemoteNode <==> ClientB
    await connectNodes(nodes[0], nodes[2])
    await connectNodes(nodes[1], nodes[2])

    dms[0].advertise(RdvNamespace(namespace))

    let
      query = dms[1].request(RdvNamespace(namespace))
      peerAttributes = await query.getPeer()

    let expectedPeerId = nodes[0].switch.peerInfo.peerId
    check:
      peerAttributes{PeerId}.get() == expectedPeerId
      peerAttributes[PeerId] == expectedPeerId
      peerAttributes.getAll(PeerId) == @[expectedPeerId]
      toHashSet(peerAttributes.getAll(MultiAddress)) ==
        toHashSet(nodes[0].switch.peerInfo.addrs)

  asyncTest "RendezVous - frequent advertise and unsubscribe with multiple clients":
    const
      namespace = "foo"
      rdvNamespace = RdvNamespace(namespace)

    # Setup: [0] ClientA, [1] ClientB, [2] ClientC, [3] RemoteNode
    let (dms, nodes) = setupDiscMngrNodes(4)
    nodes.startAndDeferStop()
    dms.deferStop()

    # Topology: Each Client <==> RemoteNode
    await connectNodes(nodes[0], nodes[3])
    await connectNodes(nodes[1], nodes[3])
    await connectNodes(nodes[2], nodes[3])

    for i in 0 ..< 10:
      dms[1].advertise(rdvNamespace) # ClientB
      dms[2].advertise(rdvNamespace) # ClientC
      let expectedPeerIds =
        @[nodes[1].switch.peerInfo.peerId, nodes[2].switch.peerInfo.peerId]

      let query = dms[0].request(rdvNamespace) # ClientA

      var seen = 0
      while seen < 2:
        let peerAttributes = await query.getPeer()
        let actualPeerId = peerAttributes{PeerId}.get()
        check actualPeerId in expectedPeerIds
        seen.inc()

      # Discovery Manager times out if there are no new Peers
      check not await query.getPeer().withTimeout(50.milliseconds)
      query.stop()

      await nodes[1].unsubscribe(namespace)
      await nodes[2].unsubscribe(namespace)

      # Ensure Discovery Manager doesn't return anything after Peers unsubscribed
      # Using different requester to avoid false positive due to no new Peers registered
      let newQuery = dms[1].request(rdvNamespace)
      check not await newQuery.getPeer().withTimeout(50.milliseconds)
      newQuery.stop()

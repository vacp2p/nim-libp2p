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

  const
    namespace = "foo"
    rdvNamespace = RdvNamespace(namespace)

  asyncTest "RendezVous - advertise and request":
    let (dms, nodes) = setupDiscMngrNodes(3)
    nodes.startAndDeferStop()
    dms.deferStop()

    let
      clientA = nodes[0]
      clientB = nodes[1]
      remoteNode = nodes[2]

    # Topology: ClientA <==> RemoteNode <==> ClientB
    await connectNodes(clientA, remoteNode)
    await connectNodes(clientB, remoteNode)

    dms[0].advertise(RdvNamespace(namespace))

    let
      query = dms[1].request(RdvNamespace(namespace))
      peerAttributes = await query.getPeer()

    let expectedPeerId = clientA.switch.peerInfo.peerId
    check:
      peerAttributes{PeerId}.get() == expectedPeerId
      peerAttributes[PeerId] == expectedPeerId
      peerAttributes.getAll(PeerId) == @[expectedPeerId]
      toHashSet(peerAttributes.getAll(MultiAddress)) ==
        toHashSet(clientA.switch.peerInfo.addrs)

  asyncTest "RendezVous - frequent advertise and unsubscribe with multiple clients":
    let (dms, nodes) = setupDiscMngrNodes(4)
    nodes.startAndDeferStop()
    dms.deferStop()

    let
      clientA = nodes[0]
      clientB = nodes[1]
      clientC = nodes[2]
      remoteNode = nodes[3]

    # Topology: Each Client <==> RemoteNode
    await connectNodes(clientA, remoteNode)
    await connectNodes(clientB, remoteNode)
    await connectNodes(clientC, remoteNode)

    for i in 0 ..< 10:
      # Use protocol directly to avoid concurrent advertise to prevent BufferStream defects
      await clientB.advertise(namespace)
      await clientC.advertise(namespace)
      let expectedPeerIds =
        @[clientB.switch.peerInfo.peerId, clientC.switch.peerInfo.peerId]

      let query = dms[0].request(rdvNamespace) # ClientA

      for i in 0 ..< expectedPeerIds.len:
        let peerAttributes = await query.getPeer()
        let actualPeerId = peerAttributes{PeerId}.get()
        check actualPeerId in expectedPeerIds

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

  asyncTest "RendezVous - time to advertise":
    let (dms, nodes) = setupDiscMngrNodes(3)
    nodes.startAndDeferStop()
    dms.deferStop()

    let
      clientA = nodes[0]
      clientB = nodes[1]
      remoteNode = nodes[2]

    # Topology: ClientA <==> RemoteNode <==> ClientB
    await connectNodes(clientA, remoteNode)
    await connectNodes(clientB, remoteNode)

    # DiscoveryManager uses RendezVousInterface with time to advertise = 100ms (see setupDiscMngrNodes).
    # Calling dm.advertise() starts a periodic advertise loop with tta as an interval.
    dms[0].advertise(RdvNamespace(namespace))

    # Time to advertise is way lower than time to live, so the peers do not expire and
    # count grows over time. We wait until at least 5 entries appear to confirm
    # that the advertise loop is running.
    checkUntilTimeout:
      remoteNode.registered.s.len == 5

  asyncTest "RendezVous - time to request":
    let (dms, nodes) = setupDiscMngrNodes(4)
    nodes.startAndDeferStop()
    dms.deferStop()

    let
      clientA = nodes[0]
      clientB = nodes[1]
      clientC = nodes[2]
      remoteNode = nodes[3]

    # Topology: Each Client <==> RemoteNode
    await connectNodes(clientA, remoteNode)
    await connectNodes(clientB, remoteNode)
    await connectNodes(clientC, remoteNode)

    # Use single protocol advertises to control timing.
    # A advertises now, B and C with delays.
    await clientA.advertise(namespace)
    asyncSpawn (
      proc() {.async.} =
        await sleepAsync(50.milliseconds)
        await clientB.advertise(namespace)
    )()
    asyncSpawn (
      proc() {.async.} =
        await sleepAsync(100.milliseconds)
        await clientC.advertise(namespace)
    )()

    # Ensure only A is registered.
    check remoteNode.registered.s.len == 1

    let expectedPeerIds =
      @[
        clientA.switch.peerInfo.peerId, clientB.switch.peerInfo.peerId,
        clientC.switch.peerInfo.peerId,
      ]

    # DiscoveryManager uses RendezVousInterface with time to request = 100ms (see setupDiscMngrNodes).
    let query = dms[0].request(rdvNamespace) # ClientA requester

    # The three getPeer() calls resolve at the ttr interval as B and C register.
    for i in 0 ..< expectedPeerIds.len:
      let peerAttributes = await query.getPeer()
      let actualPeerId = peerAttributes{PeerId}.get()
      check actualPeerId in expectedPeerIds

    query.stop()

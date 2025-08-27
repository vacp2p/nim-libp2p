{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sequtils, strutils
import chronos
import ../../libp2p/[protocols/rendezvous, switch]
import ../../libp2p/discovery/discoverymngr
import ../helpers
import ./utils

suite "RendezVous":
  teardown:
    checkTrackers()

  asyncTest "Request locally returns 0 for empty namespace":
    let (nodes, rdvs) = setupNodes(1)
    nodes.startAndDeferStop()

    const namespaceEmpty = ""
    let peerRecords = rdvs[0].requestLocally(namespaceEmpty)
    check peerRecords.len == 0

  asyncTest "Request locally returns registered peers":
    let (nodes, rdvs) = setupNodes(1)
    nodes.startAndDeferStop()

    const namespace = "foo"
    await rdvs[0].advertise(namespace)
    let peerRecords = rdvs[0].requestLocally(namespace)

    check:
      peerRecords.len == 1
      peerRecords[0] == nodes[0].peerInfo.signedPeerRecord.data

  asyncTest "Unsubscribe Locally removes registered peer":
    let (nodes, rdvs) = setupNodes(1)
    nodes.startAndDeferStop()

    const namespace = "foo"
    await rdvs[0].advertise(namespace)
    check rdvs[0].requestLocally(namespace).len == 1

    rdvs[0].unsubscribeLocally(namespace)
    let peerRecords = rdvs[0].requestLocally(namespace)
    check peerRecords.len == 0

  asyncTest "Request returns 0 for empty namespace from remote":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "empty"
    let peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check peerRecords.len == 0

  asyncTest "Request returns registered peers from remote":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    await peerRdvs[0].advertise(namespace)
    let peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[0].peerInfo.signedPeerRecord.data

  asyncTest "Unsubscribe removes registered peer from remote":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    await peerRdvs[0].advertise(namespace)
    var peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check peerRecords.len == 1

    await peerRdvs[0].unsubscribe(namespace)
    peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check peerRecords.len == 0

  asyncTest "Consecutive requests with namespace returns peers with pagination":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(11)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    await allFutures(peerRdvs.mapIt(it.advertise(namespace)))

    var data = peerNodes.mapIt(it.peerInfo.signedPeerRecord.data)
    var peerRecords = await peerRdvs[0].request(Opt.some(namespace), 5)
    check:
      peerRecords.len == 5
      peerRecords.allIt(it in data)
    data.keepItIf(it notin peerRecords)

    peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check:
      peerRecords.len == 5
      peerRecords.allIt(it in data)

    peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check peerRecords.len == 0

  asyncTest "Request without namespace returns all registered peers":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(10)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespaceFoo = "foo"
    const namespaceBar = "Bar"
    await allFutures(peerRdvs[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    let peerRecords1 = await peerRdvs[0].request()
    check peerRecords1.len == 10

    let peerRecords2 = await peerRdvs[0].request(Opt.none(string))
    check peerRecords2.len == 10

  asyncTest "Consecutive requests with namespace keep cookie and retun only new peers":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(2)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    let
      rdv0 = peerRdvs[0]
      rdv1 = peerRdvs[1]
    const namespace = "foo"

    await rdv0.advertise(namespace)
    discard await rdv0.request(Opt.some(namespace))

    await rdv1.advertise(namespace)
    let peerRecords = await rdv0.request(Opt.some(namespace))

    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[1].peerInfo.signedPeerRecord.data

  asyncTest "Various local error":
    let rdv = RendezVous.new(minDuration = 1.minutes, maxDuration = 72.hours)
    expect AdvertiseError:
      discard await rdv.request(Opt.some("A".repeat(300)))
    expect AdvertiseError:
      discard await rdv.request(Opt.some("A"), -1)
    expect AdvertiseError:
      discard await rdv.request(Opt.some("A"), 3000)
    expect AdvertiseError:
      await rdv.advertise("A".repeat(300))
    expect AdvertiseError:
      await rdv.advertise("A", 73.hours)
    expect AdvertiseError:
      await rdv.advertise("A", 30.seconds)

  test "Various config error":
    expect RendezVousError:
      discard RendezVous.new(minDuration = 30.seconds)
    expect RendezVousError:
      discard RendezVous.new(maxDuration = 73.hours)
    expect RendezVousError:
      discard RendezVous.new(minDuration = 15.minutes, maxDuration = 10.minutes)

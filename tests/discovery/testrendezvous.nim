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
import ../../libp2p/utils/offsettedseq
import ../helpers
import ./utils

suite "RendezVous":
  teardown:
    checkTrackers()

  asyncTest "Request locally returns 0 for empty namespace":
    let (nodes, rdvs) = setupNodes(1)
    nodes.startAndDeferStop()

    const namespace = ""
    check rdvs[0].requestLocally(namespace).len == 0

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
    check rdvs[0].requestLocally(namespace).len == 0

  asyncTest "Request returns 0 for empty namespace from remote":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "empty"
    check (await peerRdvs[0].request(Opt.some(namespace))).len == 0

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

    check (await peerRdvs[0].request(Opt.some(namespace))).len == 1

    await peerRdvs[0].unsubscribe(namespace)
    check (await peerRdvs[0].request(Opt.some(namespace))).len == 0

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
      peerRecords.len == 6
      peerRecords.allIt(it in data)

    check (await peerRdvs[0].request(Opt.some(namespace))).len == 0

  asyncTest "Request without namespace returns all registered peers":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(10)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespaceFoo = "foo"
    const namespaceBar = "Bar"
    await allFutures(peerRdvs[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    check (await peerRdvs[0].request()).len == 10

    check (await peerRdvs[0].request(Opt.none(string))).len == 10

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

  asyncTest "Request with namespace pagination with multiple namespaces":
    let (rendezvousNode, peerNodes, peerRdvs, _) = setupRendezvousNodeWithPeerNodes(30)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    let rdv = peerRdvs[0]

    # Register peers in different namespaces in mixed order
    const
      namespaceFoo = "foo"
      namespaceBar = "bar"
    await allFutures(peerRdvs[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[5 ..< 10].mapIt(it.advertise(namespaceBar)))
    await allFutures(peerRdvs[10 ..< 15].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[15 ..< 20].mapIt(it.advertise(namespaceBar)))

    var fooRecords = peerNodes[0 ..< 5].concat(peerNodes[10 ..< 15]).mapIt(
        it.peerInfo.signedPeerRecord.data
      )
    var barRecords = peerNodes[5 ..< 10].concat(peerNodes[15 ..< 20]).mapIt(
        it.peerInfo.signedPeerRecord.data
      )

    # Foo Page 1 with limit
    var peerRecords = await rdv.request(Opt.some(namespaceFoo), 2)
    check:
      peerRecords.len == 2
      peerRecords.allIt(it in fooRecords)
    fooRecords.keepItIf(it notin peerRecords)

    # Foo Page 2 with limit
    peerRecords = await rdv.request(Opt.some(namespaceFoo), 5)
    check:
      peerRecords.len == 5
      peerRecords.allIt(it in fooRecords)
    fooRecords.keepItIf(it notin peerRecords)

    # Foo Page 3 with the rest
    peerRecords = await rdv.request(Opt.some(namespaceFoo))
    check:
      peerRecords.len == 3
      peerRecords.allIt(it in fooRecords)
    fooRecords.keepItIf(it notin peerRecords)
    check fooRecords.len == 0

    # Foo Page 4 empty
    peerRecords = await rdv.request(Opt.some(namespaceFoo))
    check peerRecords.len == 0

    # Bar Page 1 with all
    peerRecords = await rdv.request(Opt.some(namespaceBar), 30)
    check:
      peerRecords.len == 10
      peerRecords.allIt(it in barRecords)
    barRecords.keepItIf(it notin peerRecords)
    check barRecords.len == 0

    # Register new peers
    await allFutures(peerRdvs[20 ..< 25].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[25 ..< 30].mapIt(it.advertise(namespaceBar)))

    # Foo Page 5 only new peers
    peerRecords = await rdv.request(Opt.some(namespaceFoo))
    check:
      peerRecords.len == 5
      peerRecords.allIt(
        it in peerNodes[20 ..< 25].mapIt(it.peerInfo.signedPeerRecord.data)
      )

    # Bar Page 2 only new peers
    peerRecords = await rdv.request(Opt.some(namespaceBar))
    check:
      peerRecords.len == 5
      peerRecords.allIt(
        it in peerNodes[25 ..< 30].mapIt(it.peerInfo.signedPeerRecord.data)
      )

    # All records
    peerRecords = await rdv.request(Opt.none(string))
    check peerRecords.len == 30

  asyncTest "Request with namespace with expired peers":
    let (rendezvousNode, peerNodes, peerRdvs, rdv) =
      setupRendezvousNodeWithPeerNodes(20)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    # Advertise peers
    const
      namespaceFoo = "foo"
      namespaceBar = "bar"
    await allFutures(peerRdvs[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    check:
      (await peerRdvs[0].request(Opt.some(namespaceFoo))).len == 5
      (await peerRdvs[0].request(Opt.some(namespaceBar))).len == 5

    # Overwrite register timeout loop interval
    discard rdv.deletesRegister(1.seconds)

    # Overwrite expiration times
    let now = Moment.now()
    for reg in rdv.registered.s.mitems:
      reg.expiration = now

    # Wait for the deletion
    checkUntilTimeout:
      rdv.registered.offset == 10
      rdv.registered.s.len == 0
      (await peerRdvs[0].request(Opt.some(namespaceFoo))).len == 0
      (await peerRdvs[0].request(Opt.some(namespaceBar))).len == 0

    # Advertise new peers
    await allFutures(peerRdvs[10 ..< 15].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerRdvs[15 ..< 20].mapIt(it.advertise(namespaceBar)))

    check:
      rdv.registered.offset == 10
      rdv.registered.s.len == 10
      (await peerRdvs[0].request(Opt.some(namespaceFoo))).len == 5
      (await peerRdvs[0].request(Opt.some(namespaceBar))).len == 5

  asyncTest "Cookie offset is reset to end (returns empty) then new peers are discoverable":
    let (rendezvousNode, peerNodes, peerRdvs, rdv) = setupRendezvousNodeWithPeerNodes(3)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    # Advertise two peers initially
    await allFutures(peerRdvs[0 ..< 2].mapIt(it.advertise(namespace)))

    # Build and inject overflow cookie: offset past current high()+1
    let offset = (rdv.registered.high + 1000).uint64
    let cookie = buildProtobufCookie(offset, namespace)
    peerRdvs[0].injectCookieForPeer(rendezvousNode.peerInfo.peerId, namespace, cookie)

    # First request should return empty due to clamping to high()+1
    check (await peerRdvs[0].request(Opt.some(namespace))).len == 0

    # Advertise a new peer, next request should return only the new one
    await peerRdvs[2].advertise(namespace)
    let peerRecords = await peerRdvs[0].request(Opt.some(namespace))
    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[2].peerInfo.signedPeerRecord.data

  asyncTest "Cookie offset is reset to low after flush (returns current entries)":
    let (rendezvousNode, peerNodes, peerRdvs, rdv) = setupRendezvousNodeWithPeerNodes(8)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    # Advertise 4 peers in namespace
    await allFutures(peerRdvs[0 ..< 4].mapIt(it.advertise(namespace)))

    # Expire all and flush to advance registered.offset
    discard rdv.deletesRegister(1.seconds)
    let now = Moment.now()
    for reg in rdv.registered.s.mitems:
      reg.expiration = now

    checkUntilTimeout:
      rdv.registered.s.len == 0
      rdv.registered.offset == 4

    # Advertise 4 new peers
    await allFutures(peerRdvs[4 ..< 8].mapIt(it.advertise(namespace)))

    # Build and inject underflow cookie: offset behind current low
    let offset = 0'u64
    let cookie = buildProtobufCookie(offset, namespace)
    peerRdvs[0].injectCookieForPeer(rendezvousNode.peerInfo.peerId, namespace, cookie)

    check (await peerRdvs[0].request(Opt.some(namespace))).len == 4

  asyncTest "Cookie namespace mismatch resets to low (returns peers despite offset)":
    let (rendezvousNode, peerNodes, peerRdvs, rdv) = setupRendezvousNodeWithPeerNodes(3)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    await allFutures(peerRdvs.mapIt(it.advertise(namespace)))

    # Build and inject cookie with wrong namespace
    let offset = 10.uint64
    let cookie = buildProtobufCookie(offset, "other")
    peerRdvs[0].injectCookieForPeer(rendezvousNode.peerInfo.peerId, namespace, cookie)

    check (await peerRdvs[0].request(Opt.some(namespace))).len == 3

  asyncTest "Peer default TTL is saved when advertised":
    let (rendezvousNode, peerNodes, peerRdvs, rendezvousRdv) =
      setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    let timeBefore = Moment.now()
    await peerRdvs[0].advertise(namespace)
    let timeAfter = Moment.now()

    # expiration within [timeBefore + 2hours, timeAfter + 2hours]
    check:
      # Peer Node side
      peerRdvs[0].registered.s[0].data.ttl.get == MinimumDuration.seconds.uint64
      peerRdvs[0].registered.s[0].expiration >= timeBefore + MinimumDuration
      peerRdvs[0].registered.s[0].expiration <= timeAfter + MinimumDuration
      # Rendezvous Node side
      rendezvousRdv.registered.s[0].data.ttl.get == MinimumDuration.seconds.uint64
      rendezvousRdv.registered.s[0].expiration >= timeBefore + MinimumDuration
      rendezvousRdv.registered.s[0].expiration <= timeAfter + MinimumDuration

  asyncTest "Peer TTL is saved when advertised with TTL":
    let (rendezvousNode, peerNodes, peerRdvs, rendezvousRdv) =
      setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const
      namespace = "foo"
      ttl = 3.hours
    let timeBefore = Moment.now()
    await peerRdvs[0].advertise(namespace, ttl)
    let timeAfter = Moment.now()

    # expiration within [timeBefore + ttl, timeAfter + ttl]
    check:
      # Peer Node side
      peerRdvs[0].registered.s[0].data.ttl.get == ttl.seconds.uint64
      peerRdvs[0].registered.s[0].expiration >= timeBefore + ttl
      peerRdvs[0].registered.s[0].expiration <= timeAfter + ttl
      # Rendezvous Node side
      rendezvousRdv.registered.s[0].data.ttl.get == ttl.seconds.uint64
      rendezvousRdv.registered.s[0].expiration >= timeBefore + ttl
      rendezvousRdv.registered.s[0].expiration <= timeAfter + ttl

  asyncTest "Peer can reregister to update its TTL before previous TTL expires":
    let (rendezvousNode, peerNodes, peerRdvs, rendezvousRdv) =
      setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    let now = Moment.now()

    await peerRdvs[0].advertise(namespace)
    check:
      # Peer Node side
      peerRdvs[0].registered.s.len == 1
      peerRdvs[0].registered.s[0].expiration > now
      # Rendezvous Node side
      rendezvousRdv.registered.s.len == 1
      rendezvousRdv.registered.s[0].expiration > now

    await peerRdvs[0].advertise(namespace, 5.hours)
    check:
      # Added 2nd registration
      # Updated expiration of the 1st one to the past
      # Will be deleted on deletion heartbeat
      # Peer Node side
      peerRdvs[0].registered.s.len == 2
      peerRdvs[0].registered.s[0].expiration < now
      # Rendezvous Node side
      rendezvousRdv.registered.s.len == 2
      rendezvousRdv.registered.s[0].expiration < now

    # Returns only one record
    check (await peerRdvs[0].request(Opt.some(namespace))).len == 1

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

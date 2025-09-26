{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sequtils
import strformat
import chronos
import
  ../../libp2p/[
    protocols/rendezvous,
    protocols/rendezvous/protobuf,
    peerinfo,
    switch,
    routing_record,
    crypto/crypto,
  ]
import ../../libp2p/discovery/discoverymngr
import ../../libp2p/utils/offsettedseq
import ../helpers
import ./utils

suite "RendezVous":
  teardown:
    checkTrackers()

  asyncTest "Request locally returns 0 for empty namespace":
    let nodes = setupNodes(1)
    nodes.startAndDeferStop()

    const namespace = ""
    check nodes[0].requestLocally(namespace).len == 0

  asyncTest "Request locally returns registered peers":
    let nodes = setupNodes(1)
    nodes.startAndDeferStop()

    const namespace = "foo"
    await nodes[0].advertise(namespace)
    let peerRecords = nodes[0].requestLocally(namespace)

    check:
      peerRecords.len == 1
      peerRecords[0] == nodes[0].switch.peerInfo.signedPeerRecord.data

  asyncTest "Unsubscribe Locally removes registered peer":
    let nodes = setupNodes(1)
    nodes.startAndDeferStop()

    const namespace = "foo"
    await nodes[0].advertise(namespace)
    check nodes[0].requestLocally(namespace).len == 1

    nodes[0].unsubscribeLocally(namespace)
    check nodes[0].requestLocally(namespace).len == 0

  asyncTest "Request returns 0 for empty namespace from remote":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "empty"
    check (await peerNodes[0].request(Opt.some(namespace))).len == 0

  asyncTest "Request returns registered peers from remote":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    await peerNodes[0].advertise(namespace)
    let peerRecords = await peerNodes[0].request(Opt.some(namespace))
    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[0].switch.peerInfo.signedPeerRecord.data

  asyncTest "Peer is not registered when peer record validation fails":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    peerNodes[0].switch.peerInfo.signedPeerRecord =
      createCorruptedSignedPeerRecord(peerNodes[0].switch.peerInfo.peerId)

    const namespace = "foo"
    await peerNodes[0].advertise(namespace)

    check rendezvousNode.registered.s.len == 0

  asyncTest "Unsubscribe removes registered peer from remote":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    await peerNodes[0].advertise(namespace)

    check (await peerNodes[0].request(Opt.some(namespace))).len == 1

    await peerNodes[0].unsubscribe(namespace)
    check (await peerNodes[0].request(Opt.some(namespace))).len == 0

  asyncTest "Unsubscribe for not registered namespace is ignored":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    await peerNodes[0].advertise("foo")
    await peerNodes[0].unsubscribe("bar")

    check rendezvousNode.registered.s.len == 1

  asyncTest "Consecutive requests with namespace returns peers with pagination":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(11)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    await allFutures(peerNodes.mapIt(it.advertise(namespace)))

    var data = peerNodes.mapIt(it.switch.peerInfo.signedPeerRecord.data)
    var peerRecords = await peerNodes[0].request(Opt.some(namespace), 5)
    check:
      peerRecords.len == 5
      peerRecords.allIt(it in data)
    data.keepItIf(it notin peerRecords)

    peerRecords = await peerNodes[0].request(Opt.some(namespace))
    check:
      peerRecords.len == 6
      peerRecords.allIt(it in data)

    check (await peerNodes[0].request(Opt.some(namespace))).len == 0

  asyncTest "Request without namespace returns all registered peers":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(10)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespaceFoo = "foo"
    const namespaceBar = "Bar"
    await allFutures(peerNodes[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    check (await peerNodes[0].request()).len == 10

    check (await peerNodes[0].request(Opt.none(string))).len == 10

  asyncTest "Consecutive requests with namespace keep cookie and retun only new peers":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(2)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    let
      rdv0 = peerNodes[0]
      rdv1 = peerNodes[1]
    const namespace = "foo"

    await rdv0.advertise(namespace)
    discard await rdv0.request(Opt.some(namespace))

    await rdv1.advertise(namespace)
    let peerRecords = await rdv0.request(Opt.some(namespace))

    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[1].switch.peerInfo.signedPeerRecord.data

  asyncTest "Request with namespace pagination with multiple namespaces":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(30)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    let rdv = peerNodes[0]

    # Register peers in different namespaces in mixed order
    const
      namespaceFoo = "foo"
      namespaceBar = "bar"
    await allFutures(peerNodes[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[5 ..< 10].mapIt(it.advertise(namespaceBar)))
    await allFutures(peerNodes[10 ..< 15].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[15 ..< 20].mapIt(it.advertise(namespaceBar)))

    var fooRecords = peerNodes[0 ..< 5].concat(peerNodes[10 ..< 15]).mapIt(
        it.switch.peerInfo.signedPeerRecord.data
      )
    var barRecords = peerNodes[5 ..< 10].concat(peerNodes[15 ..< 20]).mapIt(
        it.switch.peerInfo.signedPeerRecord.data
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
    await allFutures(peerNodes[20 ..< 25].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[25 ..< 30].mapIt(it.advertise(namespaceBar)))

    # Foo Page 5 only new peers
    peerRecords = await rdv.request(Opt.some(namespaceFoo))
    check:
      peerRecords.len == 5
      peerRecords.allIt(
        it in peerNodes[20 ..< 25].mapIt(it.switch.peerInfo.signedPeerRecord.data)
      )

    # Bar Page 2 only new peers
    peerRecords = await rdv.request(Opt.some(namespaceBar))
    check:
      peerRecords.len == 5
      peerRecords.allIt(
        it in peerNodes[25 ..< 30].mapIt(it.switch.peerInfo.signedPeerRecord.data)
      )

    # All records
    peerRecords = await rdv.request(Opt.none(string))
    check peerRecords.len == 30

  asyncTest "Request with namespace with expired peers":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(20)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    # Advertise peers
    const
      namespaceFoo = "foo"
      namespaceBar = "bar"
    await allFutures(peerNodes[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    check:
      (await peerNodes[0].request(Opt.some(namespaceFoo))).len == 5
      (await peerNodes[0].request(Opt.some(namespaceBar))).len == 5

    # Overwrite register timeout loop interval
    discard rendezvousNode.deletesRegister(1.seconds)

    # Overwrite expiration times
    let now = Moment.now()
    for reg in rendezvousNode.registered.s.mitems:
      reg.expiration = now

    # Wait for the deletion
    checkUntilTimeout:
      rendezvousNode.registered.offset == 10
      rendezvousNode.registered.s.len == 0
      (await peerNodes[0].request(Opt.some(namespaceFoo))).len == 0
      (await peerNodes[0].request(Opt.some(namespaceBar))).len == 0

    # Advertise new peers
    await allFutures(peerNodes[10 ..< 15].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[15 ..< 20].mapIt(it.advertise(namespaceBar)))

    check:
      rendezvousNode.registered.offset == 10
      rendezvousNode.registered.s.len == 10
      (await peerNodes[0].request(Opt.some(namespaceFoo))).len == 5
      (await peerNodes[0].request(Opt.some(namespaceBar))).len == 5

  asyncTest "Cookie offset is reset to end (returns empty) then new peers are discoverable":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(3)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    # Advertise two peers initially
    await allFutures(peerNodes[0 ..< 2].mapIt(it.advertise(namespace)))

    # Build and inject overflow cookie: offset past current high()+1
    let offset = (rendezvousNode.registered.high + 1000).uint64
    let cookie = buildProtobufCookie(offset, namespace)
    peerNodes[0].injectCookieForPeer(
      rendezvousNode.switch.peerInfo.peerId, namespace, cookie
    )

    # First request should return empty due to clamping to high()+1
    check (await peerNodes[0].request(Opt.some(namespace))).len == 0

    # Advertise a new peer, next request should return only the new one
    await peerNodes[2].advertise(namespace)
    let peerRecords = await peerNodes[0].request(Opt.some(namespace))
    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[2].switch.peerInfo.signedPeerRecord.data

  asyncTest "Cookie offset is reset to low after flush (returns current entries)":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(8)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    # Advertise 4 peers in namespace
    await allFutures(peerNodes[0 ..< 4].mapIt(it.advertise(namespace)))

    # Expire all and flush to advance registered.offset
    discard rendezvousNode.deletesRegister(1.seconds)
    let now = Moment.now()
    for reg in rendezvousNode.registered.s.mitems:
      reg.expiration = now

    checkUntilTimeout:
      rendezvousNode.registered.s.len == 0
      rendezvousNode.registered.offset == 4

    # Advertise 4 new peers
    await allFutures(peerNodes[4 ..< 8].mapIt(it.advertise(namespace)))

    # Build and inject underflow cookie: offset behind current low
    let offset = 0'u64
    let cookie = buildProtobufCookie(offset, namespace)
    peerNodes[0].injectCookieForPeer(
      rendezvousNode.switch.peerInfo.peerId, namespace, cookie
    )

    check (await peerNodes[0].request(Opt.some(namespace))).len == 4

  asyncTest "Cookie namespace mismatch resets to low (returns peers despite offset)":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(3)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    const namespace = "foo"
    await allFutures(peerNodes.mapIt(it.advertise(namespace)))

    # Build and inject cookie with wrong namespace
    let offset = 10.uint64
    let cookie = buildProtobufCookie(offset, "other")
    peerNodes[0].injectCookieForPeer(
      rendezvousNode.switch.peerInfo.peerId, namespace, cookie
    )

    check (await peerNodes[0].request(Opt.some(namespace))).len == 3

  asyncTest "Peer default TTL is saved when advertised":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    let timeBefore = Moment.now()
    await peerNodes[0].advertise(namespace)
    let timeAfter = Moment.now()

    # expiration within [timeBefore + 2hours, timeAfter + 2hours]
    check:
      # Peer Node side
      peerNodes[0].registered.s[0].data.ttl.get == MinimumDuration.seconds.uint64
      peerNodes[0].registered.s[0].expiration >= timeBefore + MinimumDuration
      peerNodes[0].registered.s[0].expiration <= timeAfter + MinimumDuration
      # Rendezvous Node side
      rendezvousNode.registered.s[0].data.ttl.get == MinimumDuration.seconds.uint64
      rendezvousNode.registered.s[0].expiration >= timeBefore + MinimumDuration
      rendezvousNode.registered.s[0].expiration <= timeAfter + MinimumDuration

  asyncTest "Peer TTL is saved when advertised with TTL":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const
      namespace = "foo"
      ttl = 3.hours
    let timeBefore = Moment.now()
    await peerNodes[0].advertise(namespace, ttl)
    let timeAfter = Moment.now()

    # expiration within [timeBefore + ttl, timeAfter + ttl]
    check:
      # Peer Node side
      peerNodes[0].registered.s[0].data.ttl.get == ttl.seconds.uint64
      peerNodes[0].registered.s[0].expiration >= timeBefore + ttl
      peerNodes[0].registered.s[0].expiration <= timeAfter + ttl
      # Rendezvous Node side
      rendezvousNode.registered.s[0].data.ttl.get == ttl.seconds.uint64
      rendezvousNode.registered.s[0].expiration >= timeBefore + ttl
      rendezvousNode.registered.s[0].expiration <= timeAfter + ttl

  asyncTest "Peer can reregister to update its TTL before previous TTL expires":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    let now = Moment.now()

    await peerNodes[0].advertise(namespace)
    check:
      # Peer Node side
      peerNodes[0].registered.s.len == 1
      peerNodes[0].registered.s[0].expiration > now
      # Rendezvous Node side
      rendezvousNode.registered.s.len == 1
      rendezvousNode.registered.s[0].expiration > now

    await peerNodes[0].advertise(namespace, 5.hours)
    check:
      # Added 2nd registration
      # Updated expiration of the 1st one to the past
      # Will be deleted on deletion heartbeat
      # Peer Node side
      peerNodes[0].registered.s.len == 2
      peerNodes[0].registered.s[0].expiration < now
      # Rendezvous Node side
      rendezvousNode.registered.s.len == 2
      rendezvousNode.registered.s[0].expiration < now

    # Returns only one record
    check (await peerNodes[0].request(Opt.some(namespace))).len == 1

  asyncTest "Peer registration is ignored if limit of 1000 registrations is reached":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    let peerRdv = peerNodes[0]

    # Create 999 registrations
    await populatePeerRegistrations(
      peerRdv, rendezvousNode, namespace, RegistrationLimitPerPeer - 1
    )

    # 1000th registration allowed
    await peerRdv.advertise(namespace)
    check rendezvousNode.registered.s.len == RegistrationLimitPerPeer

    # 1001st registration ignored, limit reached
    await peerRdv.advertise(namespace)
    check rendezvousNode.registered.s.len == RegistrationLimitPerPeer

  asyncTest "Peer can register to and unsubscribe multiple namespaces":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(3)
    (rendezvousNode & peerNodes).startAndDeferStop()

    await connectNodesToRendezvousNode(peerNodes, rendezvousNode)

    let
      joiner = peerNodes[0]
      requester1 = peerNodes[1]
      requester2 = peerNodes[2]

    const namespaces = (0 ..< 5).mapIt(&"foo{it}")

    # Join all the namespaces
    for ns in namespaces:
      await joiner.advertise(ns)

    # Assert all the namespaces return Peer
    for ns in namespaces:
      check (await requester1.request(Opt.some(ns))).len == 1

    # Assert request without namespace returns only one Peer
    check (await requester1.request()).len == 1

    # Unsubscribe subset of namespaces
    const unsubscribedNamespaces = namespaces[0 ..< 3]
    const subscribedNamespaces = namespaces[3 ..< 5]
    check:
      unsubscribedNamespaces.len == 3
      subscribedNamespaces.len == 2

    for ns in unsubscribedNamespaces:
      await joiner.unsubscribe(ns)

    # Change the requester to avoid wrong results due to request cookie and no new peers
    # Assert unsubscribed namespaces don't return Peer
    for ns in unsubscribedNamespaces:
      check (await requester2.request(Opt.some(ns))).len == 0

    # Assert still subscribed namespaces return Peer
    for ns in subscribedNamespaces:
      check (await requester2.request(Opt.some(ns))).len == 1

    # Assert request without namespace still returns only one Peer
    check (await requester2.request()).len == 1

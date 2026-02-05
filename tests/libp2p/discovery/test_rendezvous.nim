# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import sequtils, strformat, sugar, chronos, stew/byteutils
import
  ../../../libp2p/[
    protocols/rendezvous,
    protocols/rendezvous/protobuf,
    peerinfo,
    switch,
    routing_record,
    crypto/crypto,
    multicodec,
    protobuf/minprotobuf,
    utils/semaphore,
    builders,
    utils/offsettedseq,
  ]
import ../../tools/[lifecycle, topology, unittest]
import ./utils

type CustomPeerRecord* = object
  peerId*: PeerId
  seqNo*: uint64
  customField*: string

proc payloadDomain*(T: typedesc[CustomPeerRecord]): string =
  $multiCodec("libp2p-custom-peer-record")

proc payloadType*(T: typedesc[CustomPeerRecord]): seq[byte] =
  @[(byte) 0x05, (byte) 0x05]

proc init*(T: typedesc[CustomPeerRecord], peerId: PeerId, seqNo: uint64): T =
  CustomPeerRecord(peerId: peerId, seqNo: seqNo, customField: "customValue")

proc decode*(
    T: typedesc[CustomPeerRecord], buffer: seq[byte]
): Result[CustomPeerRecord, ProtoError] =
  let pb = initProtoBuffer(buffer)
  var record = CustomPeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)
  ?pb.getRequiredField(3, record.customField)

  ok(record)

proc encode*(record: CustomPeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)
  pb.write(3, record.customField)

  pb.finish()
  pb.buffer

proc checkCustomPeerRecord(
    _: CustomPeerRecord, spr: seq[byte], peerId: PeerId
): Result[void, string] {.gcsafe.} =
  if spr.len == 0:
    return err("Empty peer record")
  let signedEnv = ?SignedPayload[CustomPeerRecord].decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()

type CustomRendezVous = GenericRendezVous[CustomPeerRecord]

proc new*(
    T: typedesc[CustomRendezVous],
    rng: ref HmacDrbgContext = newRng(),
    minD = rendezvous.MinimumDuration,
    maxD = rendezvous.MaximumDuration,
    peerRecordValidator: PeerRecordValidator[CustomPeerRecord] = checkCustomPeerRecord,
): T =
  var minDuration = minD
  var maxDuration = maxD
  if minDuration < rendezvous.MinimumAcceptedDuration:
    minDuration = rendezvous.MinimumAcceptedDuration

  if maxDuration > rendezvous.MaximumDuration:
    maxDuration = rendezvous.MaximumDuration

  if minDuration >= maxDuration:
    minDuration = rendezvous.MinimumAcceptedDuration
    maxDuration = rendezvous.MaximumDuration

  let
    minTTL = minDuration.seconds.uint64
    maxTTL = maxDuration.seconds.uint64
  let rdv = T(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](),
    expiredDT: Moment.now() - 1.days,
    sema: newAsyncSemaphore(SemaphoreDefaultSize),
    minDuration: minDuration,
    maxDuration: maxDuration,
    minTTL: minTTL,
    maxTTL: maxTTL,
    peerRecordValidator: peerRecordValidator,
  )
  let pr = CustomPeerRecord.init(
    PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet(), 0
  )
  logScope:
    topics = "libp2p discovery rendezvous"
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let
        buf = await conn.readLp(4096)
        msg = Message.decode(buf).tryGet()
      case msg.msgType
      of MessageType.Register:
        await rdv.register(conn, msg.register.tryGet(), pr)
      of MessageType.RegisterResponse:
        trace "Got an unexpected Register Response", response = msg.registerResponse
      of MessageType.Unregister:
        rdv.unregister(conn, msg.unregister.tryGet())
      of MessageType.Discover:
        await rdv.discover(conn, msg.discover.tryGet())
      of MessageType.DiscoverResponse:
        trace "Got an unexpected Discover Response", response = msg.discoverResponse
    except CancelledError as exc:
      trace "cancelled rendezvous handler"
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", description = exc.msg
    finally:
      await conn.close()

  rdv.handler = handleStream
  rdv.codec = "/cust-rendezvous/1.0.0"

  return rdv

proc advertise*(
    rdv: CustomRendezVous, namespace: string, customPeerRecord: CustomPeerRecord
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  let se = SignedPayload[CustomPeerRecord].init(
    rdv.switch.peerInfo.privateKey, customPeerRecord
  ).valueOr:
    raise newException(AdvertiseError, "Failed to sign Custom Peer Record")
  let sprBuff = se.encode().valueOr:
    raise newException(AdvertiseError, "Wrong Signed Peer Record")
  await rdv.advertise(namespace, rdv.minDuration, rdv.peers, sprBuff)

suite "RendezVous":
  teardown:
    checkTrackers()

  asyncTest "Request locally returns 0 for empty namespace":
    let nodes = setupNodes(1)
    startNodesAndDeferStop(nodes)

    const namespace = ""
    check rendezvous.requestLocally(nodes[0], namespace).len == 0

  asyncTest "Request locally returns registered peers":
    let nodes = setupNodes(1)
    startNodesAndDeferStop(nodes)

    const namespace = "foo"
    await nodes[0].advertise(namespace)
    let peerRecords = rendezvous.requestLocally(nodes[0], namespace)

    check:
      peerRecords.len == 1
      peerRecords[0] == nodes[0].switch.peerInfo.signedPeerRecord.data

  asyncTest "Unsubscribe Locally removes registered peer":
    let nodes = setupNodes(1)
    startNodesAndDeferStop(nodes)

    const namespace = "foo"
    await nodes[0].advertise(namespace)
    check rendezvous.requestLocally(nodes[0], namespace).len == 1

    nodes[0].unsubscribeLocally(namespace)
    check rendezvous.requestLocally(nodes[0], namespace).len == 0

  asyncTest "Request returns 0 for empty namespace from remote":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "empty"
    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 0

  asyncTest "Request returns registered peers from remote":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    waitFor peerNodes[0].advertise(namespace)
    let peerRecords = await rendezvous.request(
      peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[0].switch.peerInfo.signedPeerRecord.data

  asyncTest "Peer is not registered when peer record validation fails":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodes(peerNodes[0], rendezvousNode)

    peerNodes[0].switch.peerInfo.signedPeerRecord =
      createCorruptedSignedPeerRecord(peerNodes[0].switch.peerInfo.peerId)

    const namespace = "foo"
    await peerNodes[0].advertise(namespace)

    check rendezvousNode.registered.s.len == 0

  asyncTest "Unsubscribe removes registered peer from remote":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodes(peerNodes[0], rendezvousNode)

    const namespace = "foo"
    await peerNodes[0].advertise(namespace)

    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 1

    await peerNodes[0].unsubscribe(namespace)
    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 0

  asyncTest "Unsubscribe for not registered namespace is ignored":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodes(peerNodes[0], rendezvousNode)

    await peerNodes[0].advertise("foo")
    await peerNodes[0].unsubscribe("bar")

    check rendezvousNode.registered.s.len == 1

  asyncTest "Consecutive requests with namespace returns peers with pagination":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(11)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

    const namespace = "foo"
    await allFutures(peerNodes.mapIt(it.advertise(namespace)))

    var data = peerNodes.mapIt(it.switch.peerInfo.signedPeerRecord.data)
    var peerRecords = waitFor rendezvous.request(
      peerNodes[0], Opt.some(namespace), Opt.some(5), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 5
      peerRecords.allIt(it in data)
    data.keepItIf(it notin peerRecords)

    peerRecords = await rendezvous.request(
      peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 6
      peerRecords.allIt(it in data)

    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 0

  asyncTest "Request without namespace returns all registered peers":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(10)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

    const namespaceFoo = "foo"
    const namespaceBar = "Bar"
    await allFutures(peerNodes[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    check (
      await rendezvous.request(
        peerNodes[0], Opt.none(string), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 10

    check (
      await rendezvous.request(
        peerNodes[0], Opt.none(string), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 10

  asyncTest "Consecutive requests with namespace keep cookie and retun only new peers":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(2)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

    let
      rdv0 = peerNodes[0]
      rdv1 = peerNodes[1]
    const namespace = "foo"

    await rdv0.advertise(namespace)
    discard await rendezvous.request(
      rdv0, Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
    )

    await rdv1.advertise(namespace)
    let peerRecords = await rendezvous.request(
      rdv0, Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
    )

    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[1].switch.peerInfo.signedPeerRecord.data

  asyncTest "Request with namespace pagination with multiple namespaces":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(30)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

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
    var peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceFoo), Opt.some(2), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 2
      peerRecords.allIt(it in fooRecords)
    fooRecords.keepItIf(it notin peerRecords)

    # Foo Page 2 with limit
    peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceFoo), Opt.some(5), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 5
      peerRecords.allIt(it in fooRecords)
    fooRecords.keepItIf(it notin peerRecords)

    # Foo Page 3 with the rest
    peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceFoo), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 3
      peerRecords.allIt(it in fooRecords)
    fooRecords.keepItIf(it notin peerRecords)
    check fooRecords.len == 0

    # Foo Page 4 empty
    peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceFoo), Opt.none(int), Opt.none(seq[PeerId])
    )
    check peerRecords.len == 0

    # Bar Page 1 with all
    peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceBar), Opt.some(30), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 10
      peerRecords.allIt(it in barRecords)
    barRecords.keepItIf(it notin peerRecords)
    check barRecords.len == 0

    # Register new peers
    await allFutures(peerNodes[20 ..< 25].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[25 ..< 30].mapIt(it.advertise(namespaceBar)))

    # Foo Page 5 only new peers
    peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceFoo), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 5
      peerRecords.allIt(
        it in peerNodes[20 ..< 25].mapIt(it.switch.peerInfo.signedPeerRecord.data)
      )

    # Bar Page 2 only new peers
    peerRecords = await rendezvous.request(
      rdv, Opt.some(namespaceBar), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 5
      peerRecords.allIt(
        it in peerNodes[25 ..< 30].mapIt(it.switch.peerInfo.signedPeerRecord.data)
      )

    # All records
    peerRecords = await rendezvous.request(
      rdv, Opt.none(string), Opt.none(int), Opt.none(seq[PeerId])
    )
    check peerRecords.len == 30

  asyncTest "Request with namespace with expired peers":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(20)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

    # Advertise peers
    const
      namespaceFoo = "foo"
      namespaceBar = "bar"
    await allFutures(peerNodes[0 ..< 5].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[5 ..< 10].mapIt(it.advertise(namespaceBar)))

    check:
      (
        await rendezvous.request(
          peerNodes[0], Opt.some(namespaceFoo), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 5

      (
        await rendezvous.request(
          peerNodes[0], Opt.some(namespaceBar), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 5

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

      (
        waitFor rendezvous.request(
          peerNodes[0], Opt.some(namespaceFoo), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 0

      (
        waitFor rendezvous.request(
          peerNodes[0], Opt.some(namespaceBar), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 0

    # Advertise new peers
    await allFutures(peerNodes[10 ..< 15].mapIt(it.advertise(namespaceFoo)))
    await allFutures(peerNodes[15 ..< 20].mapIt(it.advertise(namespaceBar)))

    check:
      rendezvousNode.registered.offset == 10
      rendezvousNode.registered.s.len == 10

      (
        await rendezvous.request(
          peerNodes[0], Opt.some(namespaceFoo), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 5

      (
        await rendezvous.request(
          peerNodes[0], Opt.some(namespaceBar), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 5

  asyncTest "Cookie offset is reset to end (returns empty) then new peers are discoverable":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(3)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

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
    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 0

    # Advertise a new peer, next request should return only the new one
    await peerNodes[2].advertise(namespace)
    let peerRecords = waitFor rendezvous.request(
      peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 1
      peerRecords[0] == peerNodes[2].switch.peerInfo.signedPeerRecord.data

  asyncTest "Cookie offset is reset to low after flush (returns current entries)":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(8)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

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

    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 4

  asyncTest "Cookie namespace mismatch resets to low (returns peers despite offset)":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(3)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

    const namespace = "foo"
    await allFutures(peerNodes.mapIt(it.advertise(namespace)))

    # Build and inject cookie with wrong namespace
    let offset = 10.uint64
    let cookie = buildProtobufCookie(offset, "other")
    peerNodes[0].injectCookieForPeer(
      rendezvousNode.switch.peerInfo.peerId, namespace, cookie
    )

    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 3

  asyncTest "Peer default TTL is saved when advertised":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

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
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodes(peerNodes[0], rendezvousNode)

    const
      namespace = "foo"
      ttl = 3.hours
    let timeBefore = Moment.now()
    await peerNodes[0].advertise(namespace, Opt.some(ttl))
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
    startNodesAndDeferStop(rendezvousNode & peerNodes)

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

    await peerNodes[0].advertise(namespace, Opt.some(5.hours))
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
    check (
      await rendezvous.request(
        peerNodes[0], Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 1

  asyncTest "Peer registration is ignored if limit of 1000 registrations is reached":
    let (rendezvousNode, peerNodes) = setupRendezvousNodeWithPeerNodes(1)
    startNodesAndDeferStop(rendezvousNode & peerNodes)

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
    startNodesAndDeferStop(rendezvousNode & peerNodes)

    await connectNodesHub(rendezvousNode, peerNodes)

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
      check (
        await rendezvous.request(
          requester1, Opt.some(ns), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 1

    # Assert request without namespace returns only one Peer
    check (
      await rendezvous.request(
        requester1, Opt.none(string), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 1

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
      check (
        await rendezvous.request(
          requester2, Opt.some(ns), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 0

    # Assert still subscribed namespaces return Peer
    for ns in subscribedNamespaces:
      check (
        await rendezvous.request(
          requester2, Opt.some(ns), Opt.none(int), Opt.none(seq[PeerId])
        )
      ).len == 1

    # Assert request without namespace still returns only one Peer
    check (
      await rendezvous.request(
        requester2, Opt.none(string), Opt.none(int), Opt.none(seq[PeerId])
      )
    ).len == 1

  asyncTest "Custom Peer Record Local Request":
    let rdv = CustomRendezVous.new()
    let switch = createSwitch()
    rdv.switch = switch
    defer:
      await rdv.switch.stop()
    await rdv.switch.start()

    const namespace = ""
    check rendezvous.requestLocally[CustomPeerRecord](rdv, namespace).len == 0

  asyncTest "Custom Peer Record Request returns registered peers from remote":
    let rendezvousNode = CustomRendezVous.new()
    let switch1 = createSwitch()
    rendezvousNode.setup(switch1)
    rendezvousNode.switch.mount(rendezvousNode)

    let peerNode = CustomRendezVous.new()
    let switch2 = createSwitch()
    peerNode.setup(switch2)
    peerNode.switch.mount(peerNode)

    defer:
      await rendezvousNode.switch.stop()
      await peerNode.switch.stop()
    await rendezvousNode.switch.start()
    await peerNode.switch.start()

    await peerNode.switch.connect(
      rendezvousNode.switch.peerInfo.peerId, rendezvousNode.switch.peerInfo.addrs
    )

    const namespace = "foo"
    let custRecord = CustomPeerRecord.init(peerNode.switch.peerInfo.peerId, 1)
    waitFor peerNode.advertise(namespace, custRecord)
    let peerRecords = await rendezvous.request[CustomPeerRecord](
      peerNode, Opt.some(namespace), Opt.none(int), Opt.none(seq[PeerId])
    )
    check:
      peerRecords.len == 1
      peerRecords[0] == custRecord

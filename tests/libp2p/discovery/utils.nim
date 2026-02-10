# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos, tables
import
  ../../../libp2p/[
    builders,
    crypto/crypto,
    peerid,
    protobuf/minprotobuf,
    protocols/rendezvous,
    protocols/rendezvous/protobuf,
    routing_record,
    switch,
  ]
import ../../tools/[crypto]

proc createSwitch*(): Switch =
  SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(MemoryAutoAddress).tryGet()])
    .withMemoryTransport()
    .withMplex()
    .withNoise()
    .build()

proc createSwitch*(rdv: RendezVous): Switch =
  var lrdv = rdv
  if rdv.isNil():
    lrdv = RendezVous.new()

  SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(MemoryAutoAddress).tryGet()])
    .withMemoryTransport()
    .withMplex()
    .withNoise()
    .withRendezVous(lrdv)
    .build()

proc setupNodes*(count: int): seq[RendezVous] =
  doAssert(count > 0, "Count must be greater than 0")

  var rdvs: seq[RendezVous] = @[]

  for x in 0 ..< count:
    var rdv: RendezVous = RendezVous.new()
    let node = createSwitch(rdv)
    rdvs.add(rdv)

  return rdvs

proc setupRendezvousNodeWithPeerNodes*(count: int): (RendezVous, seq[RendezVous]) =
  let
    rdvs = setupNodes(count + 1)
    rendezvousRdv = rdvs[0]
    peerRdvs = rdvs[1 ..^ 1]

  return (rendezvousRdv, peerRdvs)

proc connect*(dialer: RendezVous, target: RendezVous) {.async.} =
  await dialer.switch.connect(
    target.switch.peerInfo.peerId, target.switch.peerInfo.addrs
  )

proc buildProtobufCookie*(offset: uint64, namespace: string): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, offset)
  pb.write(2, namespace)
  pb.finish()
  pb.buffer

proc injectCookieForPeer*(
    rdv: RendezVous, peerId: PeerId, namespace: string, cookie: seq[byte]
) =
  discard rdv.cookiesSaved.hasKeyOrPut(peerId, {namespace: cookie}.toTable())

proc populatePeerRegistrations*(
    peerRdv: RendezVous, targetRdv: RendezVous, namespace: string, count: int
) {.async.} =
  # Test helper: quickly populate many registrations for a peer.
  # We first create a single real registration, then clone that record
  # directly into the rendezvous registry to reach the desired count fast.
  #
  # Notes:
  # - Calling advertise() concurrently results in bufferstream defect.
  # - Calling advertise() sequentially is too slow for large counts.
  await peerRdv.advertise(namespace)

  let record = targetRdv.registered.s[0]
  for i in 0 ..< count - 1:
    targetRdv.registered.s.add(record)

proc createCorruptedSignedPeerRecord*(peerId: PeerId): SignedPeerRecord =
  let wrongPrivKey = PrivateKey.random(rng[]).tryGet()
  let record = PeerRecord.init(peerId, @[])
  SignedPeerRecord.init(wrongPrivKey, record).tryGet()

proc sendRdvMessage*(
    node: RendezVous, target: RendezVous, buffer: seq[byte]
): Future[seq[byte]] {.async.} =
  let conn = await node.switch.dial(target.switch.peerInfo.peerId, RendezVousCodec)
  defer:
    await conn.close()

  await conn.writeLp(buffer)

  let response = await conn.readLp(4096)
  response

proc prepareRegisterMessage*(
    namespace: string, spr: seq[byte], ttl: Duration
): Message =
  Message(
    msgType: MessageType.Register,
    register: Opt.some(
      Register(ns: namespace, signedPeerRecord: spr, ttl: Opt.some(ttl.seconds.uint64))
    ),
  )

proc prepareDiscoverMessage*(
    ns: Opt[string] = Opt.none(string),
    limit: Opt[uint64] = Opt.none(uint64),
    cookie: Opt[seq[byte]] = Opt.none(seq[byte]),
): Message =
  Message(
    msgType: MessageType.Discover,
    discover: Opt.some(Discover(ns: ns, limit: limit, cookie: cookie)),
  )

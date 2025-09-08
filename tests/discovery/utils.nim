import chronos
import sequtils
import
  ../../libp2p/[
    builders,
    crypto/crypto,
    peerid,
    protobuf/minprotobuf,
    protocols/rendezvous,
    routing_record,
    switch,
  ]

proc createSwitch*(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init(MemoryAutoAddress).tryGet()])
  .withMemoryTransport()
  .withMplex()
  .withNoise()
  .withRendezVous(rdv)
  .build()

proc setupNodes*(count: int): seq[RendezVous] =
  doAssert(count > 0, "Count must be greater than 0")

  var rdvs: seq[RendezVous] = @[]

  for x in 0 ..< count:
    let rdv = RendezVous.new()
    let node = createSwitch(rdv)
    rdvs.add(rdv)

  return rdvs

proc setupRendezvousNodeWithPeerNodes*(count: int): (RendezVous, seq[RendezVous]) =
  let
    rdvs = setupNodes(count + 1)
    rendezvousRdv = rdvs[0]
    peerRdvs = rdvs[1 ..^ 1]

  return (rendezvousRdv, peerRdvs)

template startAndDeferStop*(nodes: seq[RendezVous]) =
  await allFutures(nodes.mapIt(it.switch.start()))
  defer:
    await allFutures(nodes.mapIt(it.switch.stop()))

proc connectNodes*[T: RendezVous](dialer: T, target: T) {.async.} =
  await dialer.switch.connect(
    target.switch.peerInfo.peerId, target.switch.peerInfo.addrs
  )

proc connectNodesToRendezvousNode*[T: RendezVous](
    nodes: seq[T], rendezvousNode: T
) {.async.} =
  for node in nodes:
    await connectNodes(node, rendezvousNode)

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
  let rng = newRng()
  let wrongPrivKey = PrivateKey.random(rng[]).tryGet()
  let record = PeerRecord.init(peerId, @[])
  SignedPeerRecord.init(wrongPrivKey, record).tryGet()

import chronos
import sequtils

import
  ../../libp2p/[
    builders,
    crypto/crypto,
    discovery/discoverymngr,
    discovery/rendezvousinterface,
    peerid,
    protobuf/minprotobuf,
    protocols/rendezvous,
    protocols/rendezvous/protobuf,
    routing_record,
    switch,
  ]

proc createSwitch*[T](rdv: RendezVous[T]): Switch =
  var lrdv = rdv
  if rdv.isNil():
    try:
      lrdv = RendezVous[PeerRecord].new(peerRecordValidator = checkPeerRecord)
    except RendezVousError:
      # If creation fails, continue with nil
      lrdv = nil

  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init(MemoryAutoAddress).tryGet()])
  .withMemoryTransport()
  .withMplex()
  .withNoise()
  .withRendezVous(lrdv)
  .build()

proc setupNodes*[T](
    count: int,
    peerRecordValidator: PeerRecordValidator[T] = checkPeerRecord,
    handler: LPProtoHandler = nil,
): seq[RendezVous[T]] =
  doAssert(count > 0, "Count must be greater than 0")

  var rdvs: seq[RendezVous[T]] = @[]

  for x in 0 ..< count:
    var rdv: RendezVous[T] =
      RendezVous[T].new(peerRecordValidator = peerRecordValidator)
    let node = createSwitch(rdv)
    rdvs.add(rdv)

  return rdvs

proc setupRendezvousNodeWithPeerNodes*[T](
    count: int,
    peerRecordValidator: PeerRecordValidator[T] = checkPeerRecord,
    handler: LPProtoHandler = nil,
): (RendezVous[T], seq[RendezVous[T]]) =
  let
    rdvs = setupNodes[T](count + 1, peerRecordValidator, handler)
    rendezvousRdv = rdvs[0]
    peerRdvs = rdvs[1 ..^ 1]

  return (rendezvousRdv, peerRdvs)

template startAndDeferStop*[T](nodes: seq[RendezVous[T]]) =
  await allFutures(nodes.mapIt(it.switch.start()))
  defer:
    await allFutures(nodes.mapIt(it.switch.stop()))

proc connectNodes*[T](dialer: RendezVous[T], target: RendezVous[T]) {.async.} =
  await dialer.switch.connect(
    target.switch.peerInfo.peerId, target.switch.peerInfo.addrs
  )

proc connectNodesToRendezvousNode*[T](
    nodes: seq[RendezVous[T]], rendezvousNode: RendezVous[T]
) {.async.} =
  for node in nodes:
    await connectNodes(node, rendezvousNode)

proc buildProtobufCookie*(offset: uint64, namespace: string): seq[byte] =
  var pb = initProtoBuffer()
  pb.write(1, offset)
  pb.write(2, namespace)
  pb.finish()
  pb.buffer

proc injectCookieForPeer*[T](
    rdv: RendezVous[T], peerId: PeerId, namespace: string, cookie: seq[byte]
) =
  discard rdv.cookiesSaved.hasKeyOrPut(peerId, {namespace: cookie}.toTable())

proc populatePeerRegistrations*[T](
    peerRdv: RendezVous[T], targetRdv: RendezVous[T], namespace: string, count: int
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

proc sendRdvMessage*[T](
    node: RendezVous[T], target: RendezVous[T], buffer: seq[byte]
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

proc setupDiscMngrNodes*(
    count: int
): (seq[DiscoveryManager], seq[RendezVous[PeerRecord]]) =
  doAssert(count > 0, "Count must be greater than 0")

  var dms: seq[DiscoveryManager] = @[]
  var nodes: seq[RendezVous[PeerRecord]] = @[]

  for x in 0 ..< count:
    let node = RendezVous[PeerRecord].new(peerRecordValidator = checkPeerRecord)
    let switch = createSwitch(node)
    nodes.add(node)

    let dm = DiscoveryManager()
    dm.add(
      RendezVousInterface.new(node, ttr = 100.milliseconds, tta = 100.milliseconds)
    )
    dms.add(dm)

  return (dms, nodes)

template deferStop*(dms: seq[DiscoveryManager]) =
  defer:
    for dm in dms:
      dm.stop()

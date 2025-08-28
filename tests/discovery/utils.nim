import sequtils
import chronos
import ../../libp2p/[protobuf/minprotobuf, protocols/rendezvous, switch, builders]

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

proc setupNodes*(count: int): (seq[Switch], seq[RendezVous]) =
  doAssert(count > 0, "Count must be greater than 0")

  var
    nodes: seq[Switch] = @[]
    rdvs: seq[RendezVous] = @[]

  for x in 0 ..< count:
    let rdv = RendezVous.new()
    let node = createSwitch(rdv)
    nodes.add(node)
    rdvs.add(rdv)

  return (nodes, rdvs)

proc setupRendezvousNodeWithPeerNodes*(
    count: int
): (Switch, seq[Switch], seq[RendezVous], RendezVous) =
  let
    (nodes, rdvs) = setupNodes(count + 1)
    rendezvousNode = nodes[0]
    rendezvousRdv = rdvs[0]
    peerNodes = nodes[1 ..^ 1]
    peerRdvs = rdvs[1 ..^ 1]

  return (rendezvousNode, peerNodes, peerRdvs, rendezvousRdv)

template startAndDeferStop*(nodes: seq[Switch]) =
  await allFutures(nodes.mapIt(it.start()))
  defer:
    await allFutures(nodes.mapIt(it.stop()))

proc connectNodes*[T: Switch](dialer: T, target: T) {.async.} =
  await dialer.connect(target.peerInfo.peerId, target.peerInfo.addrs)

proc connectNodesToRendezvousNode*[T: Switch](
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
  discard testRdv(rdv).cookiesSaved.hasKeyOrPut(peerId, {namespace: cookie}.toTable())

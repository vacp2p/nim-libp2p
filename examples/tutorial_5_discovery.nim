## # Discovery method
##
## In the [previous tutorial](tutorial_4_gossipsub.md), we built a custom protocol using [protobuf](https://developers.google.com/protocol-buffers) and
## spread informations (some metrics) on the network using gossipsub.
## For this tutorial, on the other hand, we'll go back on a simple example
## we'll try to discover a specific peer to ping on the network.
##
## First, as usual, we import the dependencies:
import chronos
import stew/byteutils

import libp2p
import libp2p/protocols/rendezvous
import libp2p/discovery/rendezvousinterface
import libp2p/discovery/discoverymngr

## We'll not use newStandardSwitch this time as we need the discovery protocol
## [RendezVous](https://github.com/libp2p/specs/blob/master/rendezvous/README.md) to be mounted on the switch using withRendezVous.
##
## Note that other discovery methods such as [Kademlia](https://github.com/libp2p/specs/blob/master/kad-dht/README.md) or [discv5](https://github.com/ethereum/devp2p/blob/master/discv5/discv5.md) exist (not everyone
## of those are implemented yet though), but to make it simple for this tutorial,
## we'll stick to RendezVous.
proc createSwitch(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withRendezVous(rdv)
    .build()

const DumbCodec = "/dumb/proto/1.0.0"
type DumbProto = ref object of LPProtocol
proc new(T: typedesc[DumbProto], nodeNumber: int): T =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "Node", nodeNumber, " received: ", string.fromBytes(await conn.readLp(1024))
    await conn.close()

  return T(codecs: @[DumbCodec], handler: handle)

## We can create our main procedure:
proc main() {.async, gcsafe.} =
  # First of all, we'll create and start a boot node that'll be
  # used as an information hub on the network
  let bootNode = createSwitch()
  await bootNode.start()

  var
    switches: seq[Switch] = @[]
    discManagers: seq[DiscoveryManager] = @[]

  for i in 0..5:
    # Create a RendezVous Protocol
    let rdv = RendezVous.new()
    # Create a switch, mount the RendezVous protocol to it, start it and
    # eventually connect it to the bootNode
    let switch = createSwitch(rdv)
    switch.mount(DumbProto.new(i))
    await switch.start()
    await switch.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)
    switches.add(switch)

    # A discovery manager is a simple tool, you set it up by adding discovery
    # interfaces (such as RendezVousInterface) then you can use it to advertise
    # something on the network or to request something from it.
    let dm = DiscoveryManager()
    # A RendezVousInterface is a RendezVous protocol wrapped to be usable by the
    # DiscoveryManager. You can initialize a time to advertise/request (tta/ttr)
    # for advertise/request every x seconds.
    dm.add(RendezVousInterface.new(rdv))
    # Each nodes of the network'll advertise on some topics (even gang or odd club)
    if i mod 2 == 0:
      dm.advertise(RdvNamespace("Even Gang"))
    else:
      dm.advertise(RdvNamespace("Odd Club"))
    discManagers.add(dm)

  let
    rdv = RendezVous.new()
    newcomer = createSwitch(rdv)
    dm = DiscoveryManager()
  await newcomer.start()
  await newcomer.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)
  dm.add(RendezVousInterface.new(rdv, ttr = 250.milliseconds))

  let query = dm.request(RdvNamespace("Odd Club"))
  for _ in 0..2:
    echo "start"
    let
      res = await query.getPeer()
    echo "0 ", res[PeerId], " ", res.getAll(MultiAddress)
    let
      conn = await newcomer.dial(res[PeerId], res.getAll(MultiAddress), DumbCodec)
    echo "1"
    await conn.writeLp("Odd Club suuuucks! Even Gang is better!")
    echo "2"
    await sleepAsync(300.milliseconds)
    await conn.close()
    echo "stop"
  query.stop()



#  # Create a "network" of six nodes looking like that:
#  # node0 <-> node1 <-> node2 <-> node3 <-> node4 <-> node5
#  var
#    switches: seq[Switch] = @[]
#    discManagers: seq[DiscoveryManager] = @[]
#  for _ in 0..5:
#    # Create a RendezVous Protocol
#    let rdv = RendezVous.new()
#    # Create a switch, mount the RendezVous protocol to it, start it and
#    # enventually connect it to the previous node in the sequence
#    let switch = createSwitch(rdv)
#    if switches.len == 0:
#      
#    await switch.start()
#    if switches.len > 0:
#      await switches[^1].connect(switch.peerInfo.peerId, switch.peerInfo.addrs)
#    switches.add(switch)
#
#    # A discovery manager is a simple tool, you setup it by adding discovery
#    # interfaces (such as RendezVousInterface) then you can use it to advertise
#    # something on the network or to request something from it.
#    let dm = DiscoveryManager()
#    # A RendezVousInterface is a RendezVous protocol wrapped to be usable by the
#    # DiscoveryManager. You can initialize a time to advertise/request (tta/ttr)
#    # for advertise/request every x seconds.
#    dm.add(RendezVousInterface.new(rdv, ttr = 250.milliseconds))
#    discManagers.add(dm)
#  
#  # The first node of the network advertise on someTopic
#  discManagers[0].advertise(RdvNamespace("someTopic"))
#  for i in 1..4:
#    # All the four "middle" nodes request informations on someTopic
#    # to make the message spread. With a time to request of 250ms, it should
#    # spread on the four nodes in a little over 1 second.
#    discard discManagers[i].request(RdvNamespace("someTopic"))
#  let
#    # The ending node request on someTopic aswell and await for information.
#    query = discManagers[5].request(RdvNamespace("someTopic"))
#    # getPeer give you a PeerAttribute containing informations about the peer.
#    # The most useful are the PeerId and the MultiAddresses
#    res = await query.getPeer()
#
#  # Now that a peer have been found, we can stop the query
#  query.stop()
#
#  doAssert(res[PeerId] == switches[0].peerInfo.peerId)
#  let resMa = res.getAll(MultiAddress)
#  for ma in resMa:
#    doAssert(ma in switches[0].peerInfo.addrs)
#  echo "Peer Found: ", res[PeerId], " ", resMa
#  # The peer Id and the address of the node0 is discovered by the node5 after
#  # being pass by all the intermediate node.
#
#  # The node5 can connect the node0 to talk about someTopic directly.
#
#  # Stop all the DiscoveryManagers
#  for dm in discManagers: dm.stop()
#
#  # Stop all the switches
#  let futStop = switches.mapIt(it.stop())
#  await allFutures(futStop)

waitFor(main())

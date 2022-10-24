## # Discovery method
##
## In the [previous tutorial](tutorial_4_gossipsub.md), we built a custom protocol using [protobuf](https://developers.google.com/protocol-buffers) and
## spread informations (some metrics) on the network using gossipsub.
## For this tutorial, on the other hand, we'll go back on a simple example
## we'll try to discover a specific peers to greet on the network.
##
## First, as usual, we import the dependencies:
import sequtils
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

# Create a really simple protocol to log one message received then close the connection
const DumbCodec = "/dumb/proto/1.0.0"
type DumbProto = ref object of LPProtocol
proc new(T: typedesc[DumbProto], nodeNumber: int, fut: Future[void]): T =
  proc handle(conn: Connection, proto: string) {.async, gcsafe.} =
    echo "Node", nodeNumber, " received: ", string.fromBytes(await conn.readLp(1024))
    await conn.close()
    fut.complete()
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
    remoteFutures: seq[Future[void]] = @[]

  for i in 0..5:
    # Create a RendezVous Protocol
    let rdv = RendezVous.new()
    # Create a remote future to await at the end of the program
    let remoteFut = newFuture[void]()
    remoteFutures.add(remoteFut)
    # Create a switch, mount the RendezVous protocol to it, start it and
    # eventually connect it to the bootNode
    let switch = createSwitch(rdv)
    switch.mount(DumbProto.new(i, remoteFut))
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
    # Each nodes of the network'll advertise on some topics (EvenGang or OddClub)
    dm.advertise(RdvNamespace(if i mod 2 == 0: "EvenGang" else: "OddClub"))
    discManagers.add(dm)

  # We can now create the newcomer, this peer'll connect to the boot node
  let
    rdv = RendezVous.new()
    newcomer = createSwitch(rdv)
    dm = DiscoveryManager()
  await newcomer.start()
  await newcomer.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)
  dm.add(RendezVousInterface.new(rdv, ttr = 250.milliseconds))

  # Use the discovery manager to find peers on the OddClub topic the greet them
  let queryOddClub = dm.request(RdvNamespace("OddClub"))
  for _ in 0..2:
    let
      # getPeer give you a PeerAttribute containing informations about the peer.
      # The most useful are the PeerId and the MultiAddresses
      res = await queryOddClub.getPeer()
      # Open a connection to the peer found to greet him
      conn = await newcomer.dial(res[PeerId], res.getAll(MultiAddress), DumbCodec)
    await conn.writeLp("Odd Club suuuucks! Even Gang is better!")
    # Uh-oh!
    await conn.close()
  queryOddClub.stop()

  # Maybe it was because he wanted to join the EvenGang
  let queryEvenGang = dm.request(RdvNamespace("EvenGang"))
  for _ in 0..2:
    let
      res = await queryEvenGang.getPeer()
      conn = await newcomer.dial(res[PeerId], res.getAll(MultiAddress), DumbCodec)
    await conn.writeLp("Even Gang is sooo laaame! Odd Club rocks!")
    # Or maybe not...
    await conn.close()
  queryEvenGang.stop()
  # What can I say, some people just want to watch the world burn... Anyway

  # Wait for all the remote futures to end
  await allFutures(remoteFutures)

  # Stop all the discovery managers
  for d in discManagers:
    d.stop()
  dm.stop()

  # Stop all the switches
  await allFutures(switches.mapIt(it.stop()))
  await allFutures(bootNode.stop(), newcomer.stop())

waitFor(main())

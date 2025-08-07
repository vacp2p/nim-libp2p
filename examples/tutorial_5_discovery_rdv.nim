{.used.}
## # Discovery Manager
##
## In the [previous tutorial](tutorial_4_gossipsub.md), we built a custom protocol using [protobuf](https://developers.google.com/protocol-buffers) and
## spread informations (some metrics) on the network using gossipsub.
## For this tutorial, on the other hand, we'll go back to a simple example
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
## Note that other discovery methods such as [Kademlia](https://github.com/libp2p/specs/blob/master/kad-dht/README.md) or [discv5](https://github.com/ethereum/devp2p/blob/master/discv5/discv5.md) exist.
proc createSwitch(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withYamux()
  .withNoise()
  .withRendezVous(rdv)
  .build()

# Create a really simple protocol to log one message received then close the stream
const DumbCodec = "/dumb/proto/1.0.0"
type DumbProto = ref object of LPProtocol
proc new(T: typedesc[DumbProto], nodeNumber: int): T =
  proc handle(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      echo "Node", nodeNumber, " received: ", string.fromBytes(await conn.readLp(1024))
    except CancelledError as e:
      raise e
    except CatchableError as e:
      echo "exception in handler", e.msg
    finally:
      await conn.close()

  return T.new(codecs = @[DumbCodec], handler = handle)

## ## Bootnodes
## The first time a p2p program is ran, he needs to know how to join
## its network. This is generally done by hard-coding a list of stable
## nodes in the binary, called "bootnodes". These bootnodes are a
## critical part of a p2p network, since they are used by every new
## user to onboard the network.
##
## By using libp2p, we can use any node supporting our discovery protocol
## (rendezvous in this case) as a bootnode. For this example, we'll
## create a bootnode, and then every peer will advertise itself on the
## bootnode, and use it to find other peers
proc main() {.async.} =
  let bootNode = createSwitch()
  await bootNode.start()

  # Create 5 nodes in the network
  var
    switches: seq[Switch] = @[]
    discManagers: seq[DiscoveryManager] = @[]

  for i in 0 .. 5:
    let rdv = RendezVous.new()
    # Create a remote future to await at the end of the program
    let switch = createSwitch(rdv)
    switch.mount(DumbProto.new(i))
    switches.add(switch)

    # A discovery manager is a simple tool, you can set it up by adding discovery
    # interfaces (such as RendezVousInterface) then you can use it to advertise
    # something on the network or to request something from it.
    let dm = DiscoveryManager()
    # A RendezVousInterface is a RendezVous protocol wrapped to be usable by the
    # DiscoveryManager.
    dm.add(RendezVousInterface.new(rdv))
    discManagers.add(dm)

    # We can now start the switch and connect to the bootnode
    await switch.start()
    await switch.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)

    # Each nodes of the network will advertise on some topics (EvenGang or OddClub)
    dm.advertise(RdvNamespace(if i mod 2 == 0: "EvenGang" else: "OddClub"))

  ## We can now create the newcomer. This peer will connect to the boot node, and use
  ## it to discover peers & greet them.
  let
    rdv = RendezVous.new()
    newcomer = createSwitch(rdv)
    dm = DiscoveryManager()
  await newcomer.start()
  await newcomer.connect(bootNode.peerInfo.peerId, bootNode.peerInfo.addrs)
  dm.add(RendezVousInterface.new(rdv, ttr = 250.milliseconds))

  # Use the discovery manager to find peers on the OddClub topic to greet them
  let queryOddClub = dm.request(RdvNamespace("OddClub"))
  for _ in 0 .. 2:
    let
      # getPeer give you a PeerAttribute containing informations about the peer.
      res = await queryOddClub.getPeer()
      # Here we will use the PeerId and the MultiAddress to greet him
      conn = await newcomer.dial(res[PeerId], res.getAll(MultiAddress), DumbCodec)
    await conn.writeLp("Odd Club suuuucks! Even Gang is better!")
    # Uh-oh!
    await conn.close()
    # Wait for the peer to close the stream
    await conn.join()
  # Queries will run in a loop, so we must stop them when we are done
  queryOddClub.stop()

  # Maybe it was because he wanted to join the EvenGang
  let queryEvenGang = dm.request(RdvNamespace("EvenGang"))
  for _ in 0 .. 2:
    let
      res = await queryEvenGang.getPeer()
      conn = await newcomer.dial(res[PeerId], res.getAll(MultiAddress), DumbCodec)
    await conn.writeLp("Even Gang is sooo laaame! Odd Club rocks!")
    # Or maybe not...
    await conn.close()
    await conn.join()
  queryEvenGang.stop()
  # What can I say, some people just want to watch the world burn... Anyway

  # Stop all the discovery managers
  for d in discManagers:
    d.stop()
  dm.stop()

  # Stop all the switches
  await allFutures(switches.mapIt(it.stop()))
  await allFutures(bootNode.stop(), newcomer.stop())

waitFor(main())

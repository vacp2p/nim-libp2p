## Mix + Kad Get Example
## Demonstrates doing an anonymous `getValue` through the mix network.
## The mix exit node dials a kad node directly on the kad wire protocol,
## so no separate gateway is needed -- mirroring how mix_ping.nim lets the
## exit node dial the Ping destination directly.

{.used.}

import chronicles, chronos, results
import std/[sequtils, strformat]
import stew/byteutils
import
  ../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/mix/mix_node,
    protocols/kademlia,
    protocols/kademlia/protobuf,
    protocols/kademlia/types,
    peerstore,
    multiaddress,
    switch,
    builders,
    multihash,
    crypto/crypto,
    crypto/secp,
  ]

const
  NumMixNodes = 10
  NumKadNodes = 3
  KadBasePort = 7400
  KadCodec = "/ipfs/kad/1.0.0"
  MaxMsgSize = 4096

proc createSwitch(
    multiAddr: MultiAddress, libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey)
): Switch =
  var rng = newRng()
  let skkey = libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  let privKey = PrivateKey(scheme: Secp256k1, skkey: skkey)
  newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupKadNodes(numNodes: int): seq[KadDHT] =
  var nodes: seq[KadDHT] = @[]

  for i in 0 ..< numNodes:
    let nodeAddr = MultiAddress.init(fmt"/ip4/127.0.0.1/tcp/{KadBasePort + i}").tryGet()
    let sw = createSwitch(nodeAddr)
    sw.peerInfo.addrs = @[nodeAddr]

    let cfg = KadDHTConfig.new(timeout = 1.seconds, quorum = 1, replication = 3)

    let kad = KadDHT.new(sw, @[], cfg)
    sw.mount(kad)
    nodes.add(kad)

  nodes

proc connectKadPeers(kad1, kad2: KadDHT) =
  discard kad1.rtable.insert(kad2.switch.peerInfo.peerId)
  discard kad2.rtable.insert(kad1.switch.peerInfo.peerId)

  kad1.switch.peerStore[AddressBook][kad2.switch.peerInfo.peerId] =
    kad2.switch.peerInfo.addrs
  kad2.switch.peerStore[AddressBook][kad1.switch.peerInfo.peerId] =
    kad1.switch.peerInfo.addrs

proc fullyConnectKad(nodes: seq[KadDHT]) =
  for i in 0 ..< nodes.len:
    for j in i + 1 ..< nodes.len:
      connectKadPeers(nodes[i], nodes[j])

proc mixKadGetSimulation() {.async: (raises: [Exception]).} =
  let mixNodeInfos = initializeMixNodes(NumMixNodes).expect("could not initialize mix nodes")
  var mixSwitches: seq[Switch] = @[]
  var mixProtos: seq[MixProtocol] = @[]

  for i, nodeInfo in mixNodeInfos:
    let sw = createSwitch(nodeInfo.multiAddr, Opt.some(nodeInfo.libp2pPrivKey))
    let mixProto = MixProtocol.new(nodeInfo, sw)
    for j in 0 ..< mixNodeInfos.len:
      if j != i:
        mixProto.nodePool.add(
          mixNodeInfos.getMixPubInfoByIndex(j).expect("could not get pub info")
        )
    # The exit node dials the kad destination on the kad wire protocol and reads
    # back a length-prefixed protobuf response.
    mixProto.registerDestReadBehavior(KadCodec, readLp(MaxMsgSize))
    sw.mount(mixProto)

    mixSwitches.add(sw)
    mixProtos.add(mixProto)

  defer:
    await mixSwitches.mapIt(it.stop()).allFutures()

  let kads = setupKadNodes(NumKadNodes)
  defer:
    await kads.mapIt(it.switch.stop()).allFutures()

  await mixSwitches.mapIt(it.start()).allFutures()
  await kads.mapIt(it.switch.start()).allFutures()
  fullyConnectKad(kads)

  let publisherKad = kads[0]
  # The destination for anonymous get: a kad node that holds the value.
  let destKad = kads[1]

  let key = MultiHash.digest("sha2-256", "libp2p-mix-get".toBytes()).get().toKey()
  let value = "contentExample".toBytes()

  # Publish once in kad via a normal (non-anonymous) put.
  (await publisherKad.putValue(key, value)).expect("publisher cant store value")

  let senderMix = mixProtos[0]

  # Build a kad wire-protocol getValue request: the same bytes dispatchGetVal sends.
  let kadRequest = Message(msgType: MessageType.getValue, key: key).encode().buffer

  # Send through the mix network. The exit node will dial destKad on KadCodec,
  # write kadRequest, read the kad protobuf response, and return it via SURB.
  let getConn = senderMix
    .toConnection(
      MixDestination.init(
        destKad.switch.peerInfo.peerId, destKad.switch.peerInfo.addrs[0]
      ),
      KadCodec,
      MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
    )
    .expect("cant build get connection")

  await getConn.writeLp(kadRequest)
  let rawResp = await getConn.readLp(MaxMsgSize)
  await getConn.close()

  if rawResp.len == 0:
    raiseAssert "get returned empty response"

  let reply = Message.decode(rawResp).valueOr:
    raiseAssert "failed to decode kad response"

  let record = reply.record.valueOr:
    raiseAssert "kad response contained no record"

  let discoveredValue = record.value.valueOr:
    raiseAssert "kad record contained no value"

  if discoveredValue != value:
    raiseAssert "get returned wrong value"

  info "Anonymous kad get succeeded",
    key = key, discoveredValue = string.fromBytes(discoveredValue)

when isMainModule:
  waitFor(mixKadGetSimulation())

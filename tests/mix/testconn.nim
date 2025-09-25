{.used.}

import results, unittest2
import std/[enumerate, sequtils]
import ../../libp2p/protocols/[mix, ping]
import ../../libp2p/[peerid, multiaddress, switch, builders]
import ../../libp2p/crypto/secp
import ../utils/async_tests
import ../helpers

proc createSwitch(
    multiAddr: MultiAddress, libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey)
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1,
    skkey:
      if libp2pPrivKey.isSome:
        libp2pPrivKey.get()
      else:
        let keyPair = SkKeyPair.random(rng[])
        keyPair.seckey,
  )
  return newStandardSwitchBuilder(some(privKey), multiAddr).build()

proc setupSwitches(numNodes: int): seq[Switch] =
  # Initialize mix nodes
  let mixNodes = initializeMixNodes(numNodes).expect("could not initialize nodes")
  var nodes: seq[Switch] = @[]
  for index, mixNode in enumerate(mixNodes):
    let pubInfo =
      mixNodes.getMixPubInfoByIndex(index).expect("could not obtain pub info")

    pubInfo.writeToFile(index).expect("could not write pub info")
    mixNode.writeToFile(index).expect("could not write mix info")

    let switch = createSwitch(mixNode.multiAddr, Opt.some(mixNode.libp2pPrivKey))
    nodes.add(switch)

  return nodes

const NoReplyProtocolCodec = "/test/1.0.0"

type NoReplyProtocol* = ref object of LPProtocol

proc newNoReplyProtocol*(
    switch: Switch, receivedMessageFut: Future[seq[byte]]
): NoReplyProtocol =
  let nrProto = NoReplyProtocol()

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var buffer: seq[byte]

    try:
      buffer = await conn.readLp(1024)
    except LPStreamError:
      discard

    await conn.close()
    receivedMessageFut.complete(buffer)

  nrProto.handler = handler
  nrProto.codec = NoReplyProtocolCodec
  nrProto

suite "Mix Protocol":
  var switches {.threadvar.}: seq[Switch]

  asyncTeardown:
    await switches.mapIt(it.stop()).allFutures()
    checkTrackers()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  asyncSetup:
    switches = setupSwitches(10)

  asyncTest "e2e - expect reply, exit != destination":
    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
          "should have initialized mix protocol"
        )
      # We'll fwd requests, so let's register how should the exit node will read responses
      proto.registerDestReadBehavior(PingCodec, readExactly(32))
      mixProto.add(proto)
      switches[index].mount(proto)

    let destNode = createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
    defer:
      await destNode.stop()

    let pingProto = Ping.new()
    destNode.mount(pingProto)

    # Start all nodes
    await switches.mapIt(it.start()).allFutures()
    await destNode.start()

    let conn = mixProto[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        PingCodec,
        Opt.some(
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1)))
        ),
      )
      .expect("could not build connection")

    let response = await pingProto.ping(conn)
    await conn.close()

    check response != 0.seconds

  asyncTest "e2e - expect no reply, exit != destination":
    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
          "should have initialized mix protocol"
        )
      mixProto.add(proto)
      switches[index].mount(proto)

    let destNode = createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
    defer:
      await destNode.stop()

    let receivedMessageFut = newFuture[seq[byte]]()
    let nrProto = newNoReplyProtocol(destNode, receivedMessageFut)
    destNode.mount(nrProto)

    # Start all nodes
    await switches.mapIt(it.start()).allFutures()
    await destNode.start()

    let conn = mixProto[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        NoReplyProtocolCodec,
      )
      .expect("could not build connection")

    let data = @[1.byte, 2, 3, 4, 5]
    await conn.writeLp(data)
    await conn.close()

    check data == await receivedMessageFut

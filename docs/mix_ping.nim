# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Mix Protocol Ping Example
##
## This example demonstrates using the Mix protocol with the Ping protocol.
## It creates a set of mix nodes that form an anonymous overlay network,
## then sends a ping through the mix network to a destination node and
## receives the response via Single Use Reply Blocks (SURBs).

{.used.}

import chronicles, chronos, results
import std/[enumerate, sequtils, os]
import
  ../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/secp,
  ]

const NumMixNodes = 10

proc createSwitch(
    multiAddr: MultiAddress, libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey)
): Switch =
  var rng = newRng()
  let skkey = libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  let privKey = PrivateKey(scheme: Secp256k1, skkey: skkey)
  newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

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

  nodes

proc mixPingSimulation() {.async: (raises: [Exception]).} =
  let switches = setupSwitches(NumMixNodes)

  defer:
    await switches.mapIt(it.stop()).allFutures()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  var mixProtos: seq[MixProtocol] = @[]

  # Set up mix protocols on each mix node
  for index, _ in enumerate(switches):
    let proto = MixProtocol.new(index, switches.len, switches[index])

    # Register how to read ping responses (32 bytes exactly)
    proto.registerDestReadBehavior(PingCodec, readExactly(32))
    mixProtos.add(proto)
    switches[index].mount(proto)

  # Create a destination node (not part of the mix network)
  let destNode = createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
  defer:
    await destNode.stop()

  let pingProto = Ping.new()
  destNode.mount(pingProto)

  # Start all switches
  await switches.mapIt(it.start()).allFutures()
  await destNode.start()

  # Pick sender (first mix node) and send ping through the mix network
  let senderIndex = 0

  info "Sending ping through mix network",
    sender = switches[senderIndex].peerInfo.peerId,
    destination = destNode.peerInfo.peerId

  # Create a connection through the mix network
  let conn = mixProtos[senderIndex]
    .toConnection(
      MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
      PingCodec,
      MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
    )
    .expect("could not build connection")

  # Send ping and wait for response through the mix network
  let response = await pingProto.ping(conn)
  await conn.close()

  info "Ping response received through mix network", rtt = response

when isMainModule:
  waitFor(mixPingSimulation())

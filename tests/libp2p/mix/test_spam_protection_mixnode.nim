# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, std/[enumerate, sequtils], os
import ./spam_protection_impl
import
  ../../../libp2p/[
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

import ../../tools/[unittest, crypto]

# Import test spam protection implementations
import ./test_spam_protection_interface

const
  NumMixNodes = 10
  RateLimitPerNode = 10 # Each node allows this many packets
  NumTestPackets = 5 # Number of packets to send in test

proc createSwitch(
    multiAddr: MultiAddress, libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey)
): Switch =
  var rng = rng()
  let skkey = libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  let privKey = PrivateKey(scheme: Secp256k1, skkey: skkey)
  return
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

  return nodes

proc deleteNodeInfoFolder() =
  if dirExists("nodeInfo"):
    removeDir("nodeInfo")

proc deletePubInfoFolder() =
  if dirExists("pubInfo"):
    removeDir("pubInfo")

suite "Spam Protection Integration Tests":
  var switches {.threadvar.}: seq[Switch]

  asyncTeardown:
    await switches.mapIt(it.stop()).allFutures()
    checkTrackers()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  asyncSetup:
    switches = setupSwitches(NumMixNodes)

  asyncTest "e2e with rate limiting spam protection":
    # Each node gets its own spam protection instance with independent rate limit
    # This reflects real-world deployment where each node independently enforces limits

    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      # Each node creates its own spam protection instance
      let spamProtection = newRateLimitSpamProtection(RateLimitPerNode)

      let proto = MixProtocol
        .new(
          index,
          switches.len,
          switches[index],
          spamProtection = Opt.some(SpamProtection(spamProtection)),
        )
        .expect("should have initialized mix protocol")

      proto.registerDestReadBehavior(PingCodec, readExactly(32))
      mixProto.add(proto)
      switches[index].mount(proto)

    let destNode = createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
    defer:
      await destNode.stop()

    let pingProto = Ping.new()
    destNode.mount(pingProto)

    await switches.mapIt(it.start()).allFutures()
    await destNode.start()

    # Send packets (within rate limit)
    for i in 0 ..< NumTestPackets:
      let conn = mixProto[0]
        .toConnection(
          MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
          PingCodec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
        )
        .expect("could not build connection")

      let response = await pingProto.ping(conn)
      await conn.close()
      check response != 0.seconds

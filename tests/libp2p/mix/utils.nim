# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, options, std/[enumerate, sequtils, tables], stew/byteutils
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/mix/sphinx,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/secp,
  ]

import ../../tools/[unittest, crypto]

proc createSwitch*(
    multiAddr: MultiAddress = MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
    libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey),
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1, skkey: libp2pPrivKey.valueOr(SkKeyPair.random(rng[]).seckey)
  )
  return
    newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupSwitches*(numNodes: int): seq[Switch] =
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

type TestDestReadBehavior* = object
  codec*: string
  callback*: DestReadBehavior

proc setupMixNodes*(
    numNodes: int,
    destReadBehavior: Opt[TestDestReadBehavior] = Opt.none(TestDestReadBehavior),
): Future[seq[MixProtocol]] {.async.} =
  var nodes: seq[MixProtocol] = @[]
  let switches = setupSwitches(numNodes)

  for index, _ in enumerate(switches):
    let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
        "should have initialized mix protocol"
      )
    if destReadBehavior.isSome():
      # We'll fwd requests, so let's register how should the exit node will read responses
      let behavior = destReadBehavior.get()
      proto.registerDestReadBehavior(behavior.codec, behavior.callback)
    nodes.add(proto)
    switches[index].mount(proto)

  await nodes.mapIt(it.switch.start()).allFutures()
  nodes

proc stopNodes*(nodes: seq[MixProtocol]) {.async.} =
  await nodes.mapIt(it.switch.stop()).allFutures()
  deleteNodeInfoFolder()
  deletePubInfoFolder()

###

const NoReplyProtocolCodec* = "/test/1.0.0"

type NoReplyProtocol* = ref object of LPProtocol
  receivedMessages*: AsyncQueue[seq[byte]]

proc newNoReplyProtocol*(): NoReplyProtocol =
  let nrProto = NoReplyProtocol()
  nrProto.receivedMessages = newAsyncQueue[seq[byte]]()

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var buffer: seq[byte]

    try:
      buffer = await conn.readLp(1024)
    except LPStreamError:
      discard

    await conn.close()
    await nrProto.receivedMessages.put(buffer)

  nrProto.handler = handler
  nrProto.codec = NoReplyProtocolCodec
  nrProto

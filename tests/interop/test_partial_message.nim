# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../libp2p/[switch, builders, peerid, wire]
import ../../libp2p/protocols/pubsub/[gossipsub, gossipsub/extensions, rpc/message]
import ../libp2p/pubsub/extensions/my_partial_message
import ../tools/[crypto, unittest]
import ./partial_message

proc sendPartialMessage(gossipsub: GossipSub): Future[void] {.async.} =
  # implements behavior of other peer 

  # give time for everything to start
  await sleepAsync(5.seconds)

  # subscribe and wait for request to be completed
  gossipsub.subscribe(partialTopic, nil, requestsPartial = true)
  await sleepAsync(1.seconds)

  # publish partial message
  await gossipsub.publishPartial(partialTopic, makePartialMessage())

proc createOtherPeer(): Switch =
  let switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  proc validateRPC(
      rpc: PartialMessageExtensionRPC
  ): Result[void, string] {.gcsafe, raises: [].} =
    return ok()

  proc onIncomingRPC(
      peer: PeerId, rpc: PartialMessageExtensionRPC
  ) {.gcsafe, raises: [].} =
    discard

  var gossipsub = GossipSub.init(
    switch = switch,
    parameters = (
      var param = GossipSubParams.init()
      param.partialMessageExtensionConfig = some(
        PartialMessageExtensionConfig(
          unionPartsMetadata: my_partial_message.unionPartsMetadata,
          validateRPC: validateRPC,
          onIncomingRPC: onIncomingRPC,
          heartbeatsTillEviction: 100,
        )
      )
      param
    ),
  )

  switch.mount(gossipsub)

  asyncSpawn sendPartialMessage(gossipsub)

  switch

suite "Gossipsub Partial Message Interop Tests with Nim nodes":
  const ourAddress = "/ip4/127.0.0.1/tcp/0"

  teardown:
    checkTrackers()

  asyncTest "Happy path":
    let otherPeerSwitch = createOtherPeer()

    await otherPeerSwitch.start()
    defer:
      await otherPeerSwitch.stop()

    check await partialMessageInteropTest(
      ourAddress, $otherPeerSwitch.peerInfo.addrs[0], otherPeerSwitch.peerInfo.peerId
    )

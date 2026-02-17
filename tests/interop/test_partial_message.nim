# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, stew/byteutils
import ../../libp2p/[switch, builders, peerid, wire]
import ../../libp2p/protocols/pubsub/[gossipsub, gossipsub/extensions, rpc/message]
import ../libp2p/pubsub/extensions/my_partial_message
import ../tools/[crypto, unittest]
import ./partial_message

proc sendPartialMessage(
    gossipsub: GossipSub, publishMessage: bool, isCorrectMessage: bool
): Future[void] {.async.} =
  # implements behavior of other peer in partial messages interop test.
  # usually this logic is implemented using other implementation, but here 
  # we are testing interop logic itself as unit test where other peer is nim node.

  # give time for nim peer to start and to connect to this peer (other peer).
  await sleepAsync(3.seconds)

  # subscribe on partial topic and wait for request to be completed by nim peer
  gossipsub.subscribe(partialTopic, nil, requestsPartial = true)
  await sleepAsync(1.seconds)

  # by publishing partial message on topic nim peer should get parts metadata 
  # associated with published message.
  if publishMessage:
    if isCorrectMessage:
      await gossipsub.publishPartial(partialTopic, makePartialMessage())
    else:
      var pm = makePartialMessage()
      pm.groupId = "wrong-id".toBytes
      await gossipsub.publishPartial(partialTopic, pm)

proc createOtherPeer(publishMessage: bool, isCorrectMessage: bool): Switch =
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

  # schedule publishing partial message, because "other peer"
  # is created and started before "nim peer".
  # scheduling will executed publish after some delay to give 
  # time for everything to bootstrap.
  asyncSpawn sendPartialMessage(gossipsub, publishMessage, isCorrectMessage)

  switch

suite "Gossipsub Partial Message Interop Tests with Nim nodes":
  const ourAddress = "/ip4/127.0.0.1/tcp/0"

  teardown:
    checkTrackers()

  asyncTest "Happy path":
    let otherPeerSwitch = createOtherPeer(true, true)

    await otherPeerSwitch.start()
    defer:
      await otherPeerSwitch.stop()

    check await partialMessageInteropTest(
      ourAddress, $otherPeerSwitch.peerInfo.addrs[0], otherPeerSwitch.peerInfo.peerId
    )

  asyncTest "Fails when wrong message is published":
    let otherPeerSwitch = createOtherPeer(true, false)

    await otherPeerSwitch.start()
    defer:
      await otherPeerSwitch.stop()

    check not await partialMessageInteropTest(
      ourAddress, $otherPeerSwitch.peerInfo.addrs[0], otherPeerSwitch.peerInfo.peerId
    )

  asyncTest "Fails when message is not published":
    let otherPeerSwitch = createOtherPeer(false, false)

    await otherPeerSwitch.start()
    defer:
      await otherPeerSwitch.stop()

    check not await partialMessageInteropTest(
      ourAddress,
      $otherPeerSwitch.peerInfo.addrs[0],
      otherPeerSwitch.peerInfo.peerId,
      timeout = 10.seconds,
    )

  asyncTest "Fails when peer is unreachable":
    const unreachableAddress = "/ip4/127.0.0.1/tcp/59999"
    let fakePeerId = PeerId.random().get()

    expect DialFailedError:
      discard
        await partialMessageInteropTest(ourAddress, unreachableAddress, fakePeerId)

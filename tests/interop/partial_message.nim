# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, stew/byteutils, tables, chronicles, sequtils
import ../../libp2p/[builders, peerid, wire]
import ../../libp2p/protocols/pubsub/[gossipsub, gossipsub/extensions, rpc/message]
import ../tools/crypto
import ../libp2p/pubsub/extensions/my_partial_message

const partialTopic* = "logos-partial"

proc makePartialMessage*(): MyPartialMessage =
  MyPartialMessage(
    groupId: "interop-group".toBytes,
    data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
  )

proc partialMessageInteropTest*(
    ourAddr: string,
    otherAddr: string,
    otherPeerId: PeerId,
    timeout: Duration = 5.minutes,
): Future[bool] {.async.} =
  # this proc implements interop test for testing gossipsub partial message extension.
  # there are two entities:
  #   - "other peer" is peer that can be implemented in any other libp2p implementation. 
  #   - "nim peer" is peer created in this proc here.
  # interop test is as follows:
  #   - "other peer" sends partial message with some data. 
  #   - "nim peer" listens on incoming messages and asserts that other peer has sent
  #     the parts metadata that nim peer expects. other peer must know what to send in advance.

  var switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init(ourAddr).tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  proc validateRPC(
      rpc: PartialMessageExtensionRPC
  ): Result[void, string] {.gcsafe, raises: [].} =
    return ok()

  var requestFulfilled = newFuture[bool]()

  proc onIncomingRPC(
      peer: PeerId, rpc: PartialMessageExtensionRPC
  ) {.gcsafe, raises: [].} =
    # other peer must publish only one partial message.
    # in this callback code asserts that other peer
    # has published exactly that message and that nim peer has received.

    if rpc.topicID != partialTopic:
      error "partial message topic did not match"
      requestFulfilled.complete(false)
      return

    let pm = makePartialMessage()
    let expectedMetadata = MyPartsMetadata.have(toSeq(pm.data.keys))

    if rpc.groupID != pm.groupId:
      error "partial message groupId did not match"
      requestFulfilled.complete(false)
      return

    if rpc.partsMetadata != expectedMetadata:
      error "parts metadata does not match"
      requestFulfilled.complete(false)
      return

    # successful interop
    requestFulfilled.complete(true)

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
  await switch.start()
  defer:
    await switch.stop()

  # other peer was started before nim peer. it is safe to connect to them
  # right away and subscribe to partial messages topic.
  await switch.connect(otherPeerId, @[MultiAddress.init(otherAddr).get()])
  gossipsub.subscribe(partialTopic, nil, requestsPartial = true)

  # wait on request to be successfully fulfilled
  let isSuccessfullyFulfilled = await requestFulfilled.withTimeout(timeout)
  return requestFulfilled.completed() and isSuccessfullyFulfilled

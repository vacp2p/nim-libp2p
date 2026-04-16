# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, nativesockets, stew/[endians2, byteutils], strutils
import
  ../../../libp2p/[
    builders,
    crypto/crypto,
    crypto/ed25519/ed25519,
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/gossipsub/extension_partial_message,
    protocols/pubsub/rpc/message,
    switch,
  ]
import ../../../tests/tools/crypto

# Peer Id

proc getNodeId*(): int =
  let hostname = getHostname()
  doAssert hostname.startsWith("node"),
    "Expected hostname like 'node42', got: " & hostname
  parseInt(hostname[4 ..^ 1])

proc nodePrivKey*(id: int): PrivateKey =
  ## Generate deterministic ED25519 private key from node ID.
  var seed: array[32, byte]
  seed[0 ..< sizeof(uint64)] = uint64(id).toBytesLE()
  let edkey = EdPrivateKey.fromSeed(seed)
  PrivateKey.init(edkey)

proc nodePeerId*(id: int): PeerId =
  ## Derive the PeerId for a given node ID.
  PeerId.init(nodePrivKey(id)).expect("valid peer id")

# Message Id

proc extractMsgId*(data: openArray[byte]): uint64 =
  ## Extract message ID from the first 8 bytes of message data (big-endian u64).
  fromBytesBE(uint64, data.toOpenArray(0, 7))

proc interopMsgIdProvider*(m: Message): Result[MessageId, ValidationResult] =
  ## Message ID provider for interop tests.
  ## Reads first 8 bytes of message data as big-endian uint64,
  ## returns base-10 string representation as bytes.
  if m.data.len < 8:
    return err(ValidationResult.Reject)
  let id = extractMsgId(m.data)
  ok(($id).toBytes())

# Node

proc createNode*(
    nodeId: int,
    listenAddr: MultiAddress,
    gossipSubParams: GossipSubParams = GossipSubParams.init(),
    partialMessageConfig: Opt[PartialMessageExtensionConfig] =
      Opt.none(PartialMessageExtensionConfig),
): GossipSub =
  let switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[listenAddr])
    .withPrivateKey(nodePrivKey(nodeId))
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

  var params = gossipSubParams
  partialMessageConfig.withValue(pmConfig):
    params.partialMessageExtensionConfig = Opt.some(pmConfig)

  let gossipsub = GossipSub.init(
    rng = rng(),
    switch = switch,
    msgIdProvider = interopMsgIdProvider,
    anonymize = true,
    verifySignature = false,
    sign = false,
    maxMessageSize = 10 * 1024 * 1024,
    parameters = params,
  )

  switch.mount(gossipsub)
  gossipsub

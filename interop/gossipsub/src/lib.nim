# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, json, nativesockets, stew/[endians2, byteutils], strutils
import
  ../../../libp2p/[
    builders,
    crypto/crypto,
    crypto/ed25519/ed25519,
    multiaddress,
    peerid,
    protocols/pubsub/gossipsub,
    protocols/pubsub/rpc/message,
    protocols/pubsub/rpc/messages,
    switch,
  ]

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
): GossipSub =
  let privKey = nodePrivKey(nodeId)

  let switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[listenAddr])
    .withPrivateKey(privKey)
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

  let gossipsub = GossipSub.init(
    switch = switch,
    msgIdProvider = interopMsgIdProvider,
    anonymize = true,
    verifySignature = false,
    sign = false,
    maxMessageSize = 10 * 1024 * 1024,
    parameters = gossipSubParams,
  )

  switch.mount(gossipsub)
  gossipsub

# Params

proc nsToDuration(ns: float64): Duration =
  int64(ns).nanoseconds()

proc getDuration(node: JsonNode, default: Duration): Duration =
  if node == nil or node.kind == JNull:
    return default

  nsToDuration(node.getFloat())

proc toGossipSubParams*(j: JsonNode): GossipSubParams =
  ## Convert JSON to GossipSubParams
  var params = GossipSubParams.init()

  params.d = j.getOrDefault("D").getInt(params.d)
  params.dLow = j.getOrDefault("Dlo").getInt(params.dLow)
  params.dHigh = j.getOrDefault("Dhi").getInt(params.dHigh)
  params.dScore = j.getOrDefault("Dscore").getInt(params.dScore)
  params.dOut = j.getOrDefault("Dout").getInt(params.dOut)
  params.dLazy = j.getOrDefault("Dlazy").getInt(params.dLazy)

  params.historyLength = j.getOrDefault("HistoryLength").getInt(params.historyLength)
  params.historyGossip = j.getOrDefault("HistoryGossip").getInt(params.historyGossip)
  params.gossipFactor = j.getOrDefault("GossipFactor").getFloat(params.gossipFactor)

  params.heartbeatInterval =
    j.getOrDefault("HeartbeatInterval").getDuration(params.heartbeatInterval)
  params.fanoutTTL = j.getOrDefault("FanoutTTL").getDuration(params.fanoutTTL)
  params.pruneBackoff = j.getOrDefault("PruneBackoff").getDuration(params.pruneBackoff)
  params.unsubscribeBackoff =
    j.getOrDefault("UnsubscribeBackoff").getDuration(params.unsubscribeBackoff)
  params.seenTTL = j.getOrDefault("SeenTTL").getDuration(params.seenTTL)

  params.floodPublish = j.getOrDefault("FloodPublish").getBool(params.floodPublish)

  params

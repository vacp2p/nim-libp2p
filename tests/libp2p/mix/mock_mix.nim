# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, options, sets, sequtils
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/mix/pool,
    protocols/mix/serialization,
    peerid,
    switch,
  ]

import ./utils

type MockMixProtocol* = ref object of MixProtocol
  surbCallIndex: int
  surbPeerSets*: seq[seq[PeerId]]
  ## Forces each SURB onto a known path by temporarily narrowing the node pool
  ## before delegating to the real buildSurb.
  ##
  ## Usage:
  ##   mock.surbPeerSets = @[
  ##     @[nodeA, nodeB, nodeC],   # candidates for SURB 0
  ##     @[nodeD, nodeE, nodeF],   # candidates for SURB 1
  ##   ]
  ## Each SURB reply path needs exactly 2 intermediary nodes. buildSurb filters
  ## out the exit node from candidates, so if the exit happens to be one of your
  ## candidates, you'd end up with too few. Provide 3+ to be safe.
  ##
  ## After the message is sent, mock.actualSurbPeers records which 2 peers were
  ## selected for each SURB, so tests can target specific nodes.
  actualSurbPeers*: seq[seq[PeerId]]

method buildSurb*(
    mock: MockMixProtocol, id: SURBIdentifier, destPeerId: PeerId, exitPeerId: PeerId
): Result[SURB, string] {.raises: [].} =
  # No forced paths configured or all sets consumed — fall back to random selection
  if mock.surbPeerSets.len == 0 or mock.surbCallIndex >= mock.surbPeerSets.len:
    return procCall buildSurb(MixProtocol(mock), id, destPeerId, exitPeerId)

  # The exit node is randomly chosen during forward path construction, so it
  # might be one of our candidates. Remove it.
  let candidates = mock.surbPeerSets[mock.surbCallIndex].filterIt(it != exitPeerId)
  doAssert candidates.len >= 2
  let peers = candidates[0 .. 1]

  # Pool must have >= PathLength(3) nodes. We keep our 2 desired peers + the
  # exit node. buildSurb's own filter removes the exit, leaving exactly our 2.
  let keepInPool = peers.toHashSet() + [exitPeerId].toHashSet()

  var removed: seq[MixPubInfo]
  for peerId in mock.nodePool.peerIds():
    if peerId notin keepInPool:
      removed.add(mock.nodePool.get(peerId).get())
      discard mock.nodePool.remove(peerId)

  let surb = procCall buildSurb(MixProtocol(mock), id, destPeerId, exitPeerId)

  for info in removed:
    mock.nodePool.add(info)

  mock.actualSurbPeers.add(peers)
  mock.surbCallIndex.inc
  surb

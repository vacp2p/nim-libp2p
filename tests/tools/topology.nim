# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos
import ../../libp2p/switch

type Connectable =
  concept a, b
      connect(a, b) is Future[void]

proc connectChain*[T: Connectable](nodes: seq[T]) {.async.} =
  ## Chain topology: 1-2-3-4-5
  ##
  ## Each node connects to its neighbor.
  mixin connect
  var futs: seq[Future[void]]
  for i in 0 ..< nodes.len - 1:
    futs.add(connect(nodes[i], nodes[i + 1]))
  await allFutures(futs)

proc connectRing*[T: Connectable](nodes: seq[T]) {.async.} =
  ## Ring topology: 1-2-3-4-5-1
  ##
  ## Like chain, but the last node also connects to the first, forming a ring.
  mixin connect
  var futs: seq[Future[void]]
  for i in 0 ..< nodes.len - 1:
    futs.add(connect(nodes[i], nodes[i + 1]))
  futs.add(connect(nodes[^1], nodes[0]))
  await allFutures(futs)

proc connectHub*[T: Connectable](hub: T, nodes: seq[T]) {.async.} =
  ## Hub topology: hub-1, hub-2, hub-3,...
  ##
  ## A central hub node connects to all other nodes.
  mixin connect
  var futs: seq[Future[void]]
  for node in nodes:
    futs.add(connect(hub, node))
  await allFutures(futs)

proc connectStar*[T: Connectable](nodes: seq[T]) {.async.} =
  ## Star/Full mesh topology: every node connects to every other node
  ##
  ## Creates a fully connected graph.
  mixin connect
  var futs: seq[Future[void]]
  for i, dialer in nodes:
    for j, listener in nodes:
      if i != j:
        futs.add(connect(dialer, listener))
  await allFutures(futs)

proc connectSparse*[T: Connectable](nodes: seq[T], degree: int = 2) {.async.} =
  ## Sparse topology: only nodes at (i mod degree == 0) connect to all others
  ##
  ## Creates a partially connected graph where only some nodes act as connectors.
  doAssert nodes.len >= degree, "nodes count needs to be greater or equal to degree"
  mixin connect
  var futs: seq[Future[void]]
  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue
    for j, listener in nodes:
      if i != j:
        futs.add(connect(dialer, listener))
  await allFutures(futs)

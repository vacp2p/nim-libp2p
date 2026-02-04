# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, sequtils
import ../../libp2p/switch
import ./futures

type
  AsyncConnectProc*[T] = proc(a, b: T): Future[void] {.async.}
  SyncConnectProc*[T] = proc(a, b: T)

# ============================================================================
# Async Topology Builders
# ============================================================================

proc connectNodesChain*[T](nodes: seq[T], connect: AsyncConnectProc[T]) {.async.} =
  ## Chain topology: 1-2-3-4-5
  ##
  ## Each node connects to its neighbor.
  var futs: seq[Future[void]]
  for i in 0 ..< nodes.len - 1:
    futs.add(connect(nodes[i], nodes[i + 1]))
  await allFuturesRaising(futs)

proc connectNodesRing*[T](nodes: seq[T], connect: AsyncConnectProc[T]) {.async.} =
  ## Ring topology: 1-2-3-4-5-1
  ##
  ## Like chain, but the last node also connects to the first, forming a ring.
  var futs: seq[Future[void]]
  for i in 0 ..< nodes.len - 1:
    futs.add(connect(nodes[i], nodes[i + 1]))
  futs.add(connect(nodes[^1], nodes[0]))
  await allFuturesRaising(futs)

proc connectNodesHub*[T](
    hub: T, nodes: seq[T], connect: AsyncConnectProc[T]
) {.async.} =
  ## Hub topology: hub-1, hub-2, hub-3,...
  ##
  ## A central hub node connects to all other nodes.
  var futs: seq[Future[void]]
  for node in nodes:
    futs.add(connect(hub, node))
  await allFuturesRaising(futs)

proc connectNodesStar*[T](nodes: seq[T], connect: AsyncConnectProc[T]) {.async.} =
  ## Star/Full mesh topology: every node connects to every other node
  ##
  ## Creates a fully connected graph.
  var futs: seq[Future[void]]
  for i, dialer in nodes:
    for j, listener in nodes:
      if i != j:
        futs.add(connect(dialer, listener))
  await allFuturesRaising(futs)

proc connectNodesSparse*[T](
    nodes: seq[T], connect: AsyncConnectProc[T], degree: int = 2
) {.async.} =
  ## Sparse topology: only nodes at (i mod degree == 0) connect to all others
  ##
  ## Creates a partially connected graph where only some nodes act as connectors.
  doAssert nodes.len >= degree, "nodes count needs to be greater or equal to degree"
  var futs: seq[Future[void]]
  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue
    for j, listener in nodes:
      if i != j:
        futs.add(connect(dialer, listener))
  await allFuturesRaising(futs)

# ============================================================================
# Sync Topology Builders
# ============================================================================

proc connectNodesChain*[T](nodes: seq[T], connect: SyncConnectProc[T]) =
  ## Chain topology: 1-2-3-4-5
  ##
  ## Each node connects to its neighbor.
  for i in 0 ..< nodes.len - 1:
    connect(nodes[i], nodes[i + 1])

proc connectNodesRing*[T](nodes: seq[T], connect: SyncConnectProc[T]) =
  ## Ring topology: 1-2-3-4-5-1
  ##
  ## Like chain, but the last node also connects to the first, forming a ring.
  for i in 0 ..< nodes.len - 1:
    connect(nodes[i], nodes[i + 1])
  connect(nodes[^1], nodes[0])

proc connectNodesHub*[T](hub: T, nodes: seq[T], connect: SyncConnectProc[T]) =
  ## Hub topology: hub-1, hub-2, hub-3,...
  ##
  ## A central hub node connects to all other nodes.
  for node in nodes:
    connect(hub, node)

proc connectNodesStar*[T](nodes: seq[T], connect: SyncConnectProc[T]) =
  ## Star/Full mesh topology: every node connects to every other node
  ##
  ## Creates a fully connected graph.
  for i, dialer in nodes:
    for j, listener in nodes:
      if i != j:
        connect(dialer, listener)

proc connectNodesSparse*[T](nodes: seq[T], connect: SyncConnectProc[T], degree: int = 2) =
  ## Sparse topology: only nodes at (i mod degree == 0) connect to all others
  ##
  ## Creates a partially connected graph where only some nodes act as connectors.
  doAssert nodes.len >= degree, "nodes count needs to be greater or equal to degree"
  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue
    for j, listener in nodes:
      if i != j:
        connect(dialer, listener)

# ============================================================================
# Lifecycle Helpers
# ============================================================================

proc startNodes*[T](nodes: seq[T]) {.async.} =
  await allFuturesRaising(nodes.mapIt(it.switch.start()))

proc stopNodes*[T](nodes: seq[T]) {.async.} =
  await allFuturesRaising(nodes.mapIt(it.switch.stop()))

template startNodesAndDeferStop*[T](nodes: seq[T]): untyped =
  await startNodes(nodes)
  defer:
    await stopNodes(nodes)

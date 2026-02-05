# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, sequtils
import ../../libp2p/switch

proc startNodes*[T](nodes: seq[T]) {.async.} =
  await allFutures(nodes.mapIt(it.switch.start()))

proc stopNodes*[T](nodes: seq[T]) {.async.} =
  when compiles(nodes[0].stop()):
    await allFutures(nodes.mapIt(it.stop()))
  await allFutures(nodes.mapIt(it.switch.stop()))

template startNodesAndDeferStop*[T](nodes: seq[T]): untyped =
  await startNodes(nodes)
  defer:
    await stopNodes(nodes)

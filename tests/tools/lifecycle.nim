# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, sequtils
import ../../libp2p/switch
import ./futures

proc startNodes*(nodes: seq[Switch]) {.async.} =
  await allFuturesRaising(nodes.mapIt(it.start()))

proc stopNodes*(nodes: seq[Switch]) {.async.} =
  await allFuturesRaising(nodes.mapIt(it.stop()))

template startAndDeferStop*(nodes: seq[Switch]): untyped =
  await startNodes(nodes)
  defer:
    await stopNodes(nodes)

proc startNodes*[T](nodes: seq[T]) {.async.} =
  await startNodes(nodes.mapIt(it.switch))

  when compiles(nodes[0].start()):
    await allFuturesRaising(nodes.mapIt(it.start()))

proc stopNodes*[T](nodes: seq[T]) {.async.} =
  when compiles(nodes[0].stop()):
    await allFuturesRaising(nodes.mapIt(it.stop()))

  await stopNodes(nodes.mapIt(it.switch))

template startAndDeferStop*[T](nodes: seq[T]): untyped =
  await startNodes(nodes)
  defer:
    await stopNodes(nodes)

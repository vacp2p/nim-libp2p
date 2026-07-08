# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, sequtils
import ../../libp2p/switch
import ./futures

proc startNodes*(nodes: seq[Switch]) {.async.} =
  chronos.await(allFuturesRaising(nodes.mapIt(it.start())))

proc stopNodes*(nodes: seq[Switch]) {.async.} =
  chronos.await(allFuturesRaising(nodes.mapIt(it.stop())))

template startAndDeferStop*(nodes: seq[Switch]): untyped =
  chronos.await(startNodes(nodes))
  defer:
    chronos.await(stopNodes(nodes))

proc startNodes*[T](nodes: seq[T]) {.async.} =
  chronos.await(startNodes(nodes.mapIt(it.switch)))

  when compiles(nodes[0].start()):
    chronos.await(allFuturesRaising(nodes.mapIt(it.start())))

proc stopNodes*[T](nodes: seq[T]) {.async.} =
  when compiles(nodes[0].stop()):
    chronos.await(allFuturesRaising(nodes.mapIt(it.stop())))

  chronos.await(stopNodes(nodes.mapIt(it.switch)))

template startAndDeferStop*[T](nodes: seq[T]): untyped =
  chronos.await(startNodes(nodes))
  defer:
    chronos.await(stopNodes(nodes))

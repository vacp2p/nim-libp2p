# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../utils
import ../../helpers

suite "Quic":
  teardown:
    checkTrackers()

  ## if numberOfNodes is small (< 10) tests pass 
  ## if --mm:[orc,arc,boehm,markAndSweep] tests pass (if --mm:refc test fails)
  ## in ci; tests are passing on some environments (mm:refc)

  asyncTest "Random Nil Pointer Dereference Test":
    let
      numberOfNodes = 15
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

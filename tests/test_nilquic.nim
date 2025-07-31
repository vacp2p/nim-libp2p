{.used.}

import utils/async_tests
import pubsub/utils

suite "quic":
  asyncTest "Nil":
    const numberOfNodes = 10
    let nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
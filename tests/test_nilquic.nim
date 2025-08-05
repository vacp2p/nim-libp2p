{.used.}

import utils/async_tests
import pubsub/utils

suite "quic":
  asyncTest "Nil":
    const numberOfNodes = 10
    let nodes = generateNodes(numberOfNodes)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

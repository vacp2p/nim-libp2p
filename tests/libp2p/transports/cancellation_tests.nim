# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils
import chronos
import ../../../libp2p/[stream/connection, transports/transport, multiaddress]
import ../../tools/[unittest]
import ./utils

const CancelSteps = 12 ## Poll steps to walk the cancel through, one dial per step.

template cancellationTransportTest*(provider: TransportProvider, address: string) =
  block:
    let transportProvider = provider

    asyncTest "a dial cancelled at any point leaves no socket open":
      let ma = @[MultiAddress.init(address).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()

      var accepted: seq[RawConn]

      proc acceptLoop() {.async: (raises: []).} =
        while true:
          try:
            let conn = await server.accept()
            if not conn.isNil():
              accepted.add(conn)
          except CatchableError:
            return

      let accepting = acceptLoop()
      defer:
        await accepting.cancelAndWait()
        await allFutures(accepted.mapIt(it.close()))
        await allFutures(client.stop(), server.stop())

      var cancelledDials = 0
      for steps in 0 .. CancelSteps:
        let dialFut = client.dial("", server.addrs[0])
        for _ in 0 ..< steps:
          await sleepAsync(0.milliseconds)

        await dialFut.cancelAndWait()

        # A dial that won the race with the cancel hands back a connection.
        if dialFut.completed():
          let conn = dialFut.value()
          if not conn.isNil():
            await conn.close()
        elif dialFut.cancelled():
          cancelledDials.inc()

      check cancelledDials > 0

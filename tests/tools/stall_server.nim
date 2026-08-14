# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sequtils
import chronos, results
import ../../libp2p/multiaddress

type StallServer* = ref object
  ## A remote that accepts and never speaks: the dialer blocks in the handshake.
  server: StreamServer
  accepted: seq[StreamTransport]
  address*: MultiAddress

proc startStallServer*(): StallServer =
  let stall = StallServer()

  proc acceptAndStall(
      server: StreamServer, client: StreamTransport
  ) {.async: (raises: []).} =
    stall.accepted.add(client)

  stall.server =
    createStreamServer(initTAddress("127.0.0.1:0"), acceptAndStall, {ReuseAddr})
  stall.server.start()
  # `local` carries the address the socket really bound, port 0 resolved.
  stall.address = MultiAddress.init(stall.server.local).tryGet()
  stall

proc waitAccepted*(stall: StallServer) {.async: (raises: [CancelledError]).} =
  ## Wait for the accept: a fixed delay races the next dial on a slow runner.
  while stall.accepted.len == 0:
    await sleepAsync(10.milliseconds)

proc stop*(stall: StallServer) {.async: (raises: []).} =
  # `stop2` over `stop`: the raising variant would break `raises: []` here.
  stall.server.stop2().isOkOr:
    raiseAssert "stall server stop failed"
  await stall.server.closeWait()
  await noCancel allFutures(stall.accepted.mapIt(it.closeWait()))

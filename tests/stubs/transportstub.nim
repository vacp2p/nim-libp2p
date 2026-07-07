# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

{.push raises: [].}

import chronos
import
  ../../libp2p/[
    transports/transport,
    transports/memorytransport,
    upgrademngrs/upgrade,
    crypto/crypto,
  ]

type
  StubAcceptBehavior* = enum
    RaiseAlways ## every accept raises: the transport can never accept
    NilAlways ## every accept returns nil: the switch's non-fatal branch
    NilThenAccept ## return nil `nilCount` times, then accept normally

  MemoryTransportStub* = ref object of MemoryTransport
    behavior: StubAcceptBehavior
    nilCount: int ## for NilThenAccept: how many nils before accepting normally
    acceptCalls*: int ## number of times accept was invoked

proc new*(
    T: typedesc[MemoryTransportStub],
    upgrade: Upgrade,
    rng: Rng,
    behavior: StubAcceptBehavior,
    nilCount: int = 0,
): T =
  let self = T(upgrader: upgrade, rng: rng, behavior: behavior, nilCount: nilCount)
  procCall Transport(self).initialize()
  self

method accept*(
    self: MemoryTransportStub
): Future[RawConn] {.async: (raises: [transport.TransportError, CancelledError]).} =
  inc self.acceptCalls

  case self.behavior
  of RaiseAlways:
    raise newException(MemoryTransportError, "stub accept always fails")
  of NilAlways:
    # the switch retries immediately whenever accept returns nil.
    # without an await here, that retry loop would run non-stop and never let any
    # other async task run, so the test would hang.
    # sleepAsync(0) pauses this task for an instant each retry, letting the rest
    # of the test run. a real transport's accept pauses here anyway while it waits
    # for a connection.
    await sleepAsync(0.milliseconds)
    return nil
  of NilThenAccept:
    if self.acceptCalls <= self.nilCount:
      # pause an instant each retry, else this loop runs non-stop and hangs the test
      await sleepAsync(0.milliseconds)
      return nil
    # accept normally by delegating to the base transport
    return await procCall MemoryTransport(self).accept()

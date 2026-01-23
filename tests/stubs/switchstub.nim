# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

{.push raises: [].}

import chronos
import ../../libp2p/[peerid, multiaddress, switch]

type
  SwitchStub* = ref object of Switch
    switch*: Switch
    connectStub*: connectStubType

  connectStubType* = proc(
    self: SwitchStub,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
  ): Future[void] {.async: (raises: [DialFailedError, CancelledError]).}

method connect*(
    self: SwitchStub,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
) {.async: (raises: [DialFailedError, CancelledError]).} =
  if (self.connectStub != nil):
    await self.connectStub(self, peerId, addrs, forceDial, reuseConnection, dir)
  else:
    await self.switch.connect(peerId, addrs, forceDial, reuseConnection, dir)

proc new*(
    T: typedesc[SwitchStub], switch: Switch, connectStub: connectStubType = nil
): T =
  return SwitchStub(
    switch: switch,
    peerInfo: switch.peerInfo,
    ms: switch.ms,
    transports: switch.transports,
    connManager: switch.connManager,
    peerStore: switch.peerStore,
    dialer: switch.dialer,
    nameResolver: switch.nameResolver,
    services: switch.services,
    connectStub: connectStub,
  )

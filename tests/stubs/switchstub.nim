# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import chronos
import ../../libp2p/[peerid, multiaddress, switch]

type
  SwitchStub* = ref object of Switch
    switch*: Switch
    connectStub*: proc(): Future[void] {.async.}

method connect*(
 self: SwitchStub,
 peerId: PeerId,
 addrs: seq[MultiAddress],
 forceDial = false,
 reuseConnection = true,
 upgradeDir = Direction.Out) {.async.} =
  if (self.connectStub != nil):
    await self.connectStub()
  else:
    await self.switch.connect(peerId, addrs, forceDial, reuseConnection, upgradeDir)

proc new*(T: typedesc[SwitchStub], switch: Switch, connectStub: proc (): Future[void] {.async.} = nil): T =
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
    connectStub: connectStub)

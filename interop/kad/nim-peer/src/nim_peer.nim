# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, libp2p, sequtils
import ../../../../libp2p
import ../../../../libp2p/protocols/kademlia

const
  PeerIP: string = "127.0.0.1"
  PeerPort: int = 4141
  OurIP: string = "127.0.0.1"
  OurPort: int = 3131

proc main() {.async.} =
  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/" & OurIP & "/tcp/" & $OurPort).tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  let
    peerId = PeerId.init(readFile("../rust-peer/peer.id")).get()
    peerMa = MultiAddress.init("/ip4/" & PeerIP & "/tcp/" & $PeerPort).get()
    kad = KadDHT.new(
      switch,
      bootstrapNodes = @[(peerId, @[peerMa])],
      config = KadDHTConfig.new(quorum = 1),
    )

  switch.mount(kad)
  await sleepAsync(5.seconds)

  await switch.start()
  defer:
    await switch.stop()

  let key: Key = "key".mapIt(byte(it))
  let value = @[1.byte, 2, 3, 4, 5]

  let res = await kad.putValue(key, value)
  if res.isErr():
    echo "putValue failed: ", res.error
    quit(1)

  await sleepAsync(2.seconds)

  # try to get the inserted value from peer
  if (await kad.getValue(key)).get().value != value:
    echo "Get value did not return correct value"
    quit(1)

when isMainModule:
  if waitFor(waitForService(PeerIP, Port(PeerPort))):
    waitFor(main())
  else:
    quit("timeout waiting for service", 1)

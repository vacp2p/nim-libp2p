# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, stew/byteutils
import ../../../../libp2p
import ../../../../libp2p/protocols/kademlia

const
  PeerIP: string = "127.0.0.1"
  PeerPort: int = 4141
  PeerAddr: string = "/ip4/" & PeerIP & "/tcp/" & $PeerPort
  OurIP: string = "127.0.0.1"
  OurPort: int = 3131
  OurAddr: string = "/ip4/" & OurIP & "/tcp/" & $OurPort

proc main() {.async.} =
  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(OurAddr).tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  let
    peerId = PeerId.init(readFile("../rust-peer/peer.id")).get()
    peerMa = MultiAddress.init(PeerAddr).get()
    kad = KadDHT.new(
      switch,
      bootstrapNodes = @[(peerId, @[peerMa])],
      config = KadDHTConfig.new(quorum = 1),
    )

  switch.mount(kad)

  # wait for rust's kad to be ready
  await sleepAsync(5.seconds)

  await switch.start()
  defer:
    await switch.stop()

  let key: Key = "key".toBytes()
  let value = "value".toBytes()

  let res = await kad.putValue(key, value)
  if res.isErr():
    echo "putValue failed: ", res.error
    quit(1)

  # wait for rust's kad to store the value
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

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
import ../../../../libp2p/[wire, protocols/kademlia]

const
  PeerAddr: string = "/ip4/127.0.0.1/tcp/4141"
  OurAddr: string = "/ip4/127.0.0.1/tcp/3131"

proc kadInteropTest(otherPeerId: PeerId): Future[bool] {.async.} =
  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(OurAddr).tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  let kad = KadDHT.new(
    switch,
    bootstrapNodes = @[(otherPeerId, @[MultiAddress.init(PeerAddr).get()])],
    config = KadDHTConfig.new(quorum = 1),
  )

  switch.mount(kad)

  await switch.start()
  defer:
    await switch.stop()

  let key: Key = "key".toBytes()
  let value = "value".toBytes()

  let res = await kad.putValue(key, value)
  if res.isErr():
    echo "putValue failed: ", res.error
    return false

  # wait for other peer's kad to store the value
  await sleepAsync(2.seconds)

  # try to get the inserted value from peer
  if (await kad.getValue(key)).get().value != value:
    echo "Get value did not return correct value"
    return false

  return true

when isMainModule:
  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(5.seconds))

    let otherPeerId = PeerId.init(readFile("../rust-peer/peer.id")).get()
    let success = waitFor(kadInteropTest(otherPeerId))
    if success:
      echo "Kademlia introp test successfull"
    else:
      quit("Kademlia introp test failed", 1)
  else:
    quit("timeout waiting for service", 1)

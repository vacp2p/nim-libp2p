# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, stew/byteutils
import ../../libp2p/[switch, builders, peerid, protocols/kademlia, wire]
import ../tools/crypto

proc kadInteropTest*(
    ourAddr: string, otherAddr: string, otherPeerId: PeerId
): Future[bool] {.async.} =
  ## Reusable Kademlia DHT interoperability test
  ## This proc can be used with any peer (nim-based or from other implementations)
  ## The peer at otherAddr must already be running before calling this
  var switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init(ourAddr).tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  let kad = KadDHT.new(
    switch,
    bootstrapNodes = @[(otherPeerId, @[MultiAddress.init(otherAddr).get()])],
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

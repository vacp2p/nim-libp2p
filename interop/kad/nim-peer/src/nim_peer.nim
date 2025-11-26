# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import net, chronos, libp2p, sequtils
import libp2p/protocols/kademlia

proc waitForService(
    host: string, port: Port, retries: int = 20, delay: Duration = 500.milliseconds
): Future[bool] {.async.} =
  for i in 0 ..< retries:
    try:
      var s = newSocket()
      s.connect(host, port)
      s.close()
      return true
    except OSError:
      discard
    await sleepAsync(delay)
  return false

proc main() {.async.} =
  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/3131").tryGet()])
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

  let
    peerId = PeerId.init(readFile("../rust-peer/peer.id")).get()
    peerMa = MultiAddress.init("/ip4/127.0.0.1/tcp/4141").get()
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
    quit(1)

  await kad.addProvider(key.toCid())
  if (await kad.getProviders(key)).len() != 1:
    quit(1)

when isMainModule:
  if waitFor(waitForService("127.0.0.1", Port(4141))):
    waitFor(main())
  else:
    quit("timeout waiting for service", 1)

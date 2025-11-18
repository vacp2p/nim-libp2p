# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import net, os, chronos, chronicles, libp2p
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
  if paramCount() != 1:
    quit("Usage: nim r src/nim_peer.nim <rust-peerid>", 1)

  # ensure peers are started
  await sleepAsync(3.seconds)

  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/3131").tryGet()])
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

  let
    (rustPeerId, rustMa) = parseFullAddress(
        MultiAddress.init("/ip4/127.0.0.1/4141/p2p/" & paramStr(1))
      )
      .get()
    kad = KadDHT.new(switch)

  switch.mount(kad)
  await kad.bootstrap(@[rustPeerInfo])

  await switch.start()
  defer:
    await switch.stop()

  let key = kad.rtable.selfId
  let value = @[1.byte, 2, 3, 4, 5]

  # send a put value to peers
  discard await kad2.putValue(key, value)

  # TODO: go peer

  await sleepAsync(2.seconds)

  # TODO: check if success file is present

when isMainModule:
  if waitFor(waitForService("127.0.0.1", Port(4141))):
    waitFor(main())
  else:
    quit("timeout waiting for service", 1)

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import net, os, chronos
import ../../../../libp2p
import
  ../../../../libp2p/[
    wire,
    protocols/connectivity/autonatv2/service,
    protocols/connectivity/autonatv2/types,
  ]

# Note: ipv6 is intentionally used here as it ensures ipv6 interop with other implementation.
const
  OurAddr = "/ip6/::1/tcp/3030"
  PeerAddr = "/ip6/::1/tcp/4040"

proc autonatInteropTest(otherPeerId: PeerId): Future[bool] {.async.} =
  var src = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(OurAddr).get()])
    .withAutonatV2Server()
    .withAutonatV2(
      serviceConfig = AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds))
    )
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

  let awaiter = newFuture[void]()

  proc statusAndConfidenceHandler(
      networkReachability: NetworkReachability, confidence: Opt[float]
  ) {.async: (raises: [CancelledError]).} =
    if networkReachability != NetworkReachability.Unknown and confidence.isSome() and
        confidence.get() >= 0.3:
      if not awaiter.finished:
        awaiter.complete()

  let service = cast[AutonatV2Service](src.services[1])
  service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

  await src.start()
  await src.connect(otherPeerId, @[MultiAddress.init(PeerAddr).get()])

  # await for network reachability with some timeout, 
  # to prevent waiting indefinitely
  await awaiter.wait(5.minutes)

  echo "Network reachability: ", service.networkReachability

  # if awaiter has completed then autonat tests has passed.
  return awaiter.completed()

when isMainModule:
  if paramCount() != 1:
    quit("Usage: nim r src/nim_peer.nim <peerid>", 1)

  let ta = initTAddress(MultiAddress.init(PeerAddr).get()).get()
  if waitFor(waitForTCPServer(ta)):
    # ensure other peer has fully started
    waitFor(sleepAsync(3.seconds))

    let otherPeerId = PeerId.init(paramStr(1)).get()
    let success = waitFor(autonatInteropTest(otherPeerId))
    if success:
      echo "Autonatv2 introp test was successfull"
    else:
      quit("Autonatv2 introp test has failed", 1)
  else:
    quit("timeout waiting for service", 1)

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import net, chronos
import
  ../../libp2p/[
    builders,
    peerid,
    wire,
    protocols/connectivity/autonatv2/service,
    protocols/connectivity/autonatv2/types,
  ]

proc autonatInteropTest*(
    ourAddr: string, otherAddr: string, otherPeerId: PeerId
): Future[bool] {.async.} =
  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(ourAddr).get()])
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

  let service = cast[AutonatV2Service](switch.services[1])
  service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

  await switch.start()
  defer:
    await switch.stop()
  await switch.connect(otherPeerId, @[MultiAddress.init(otherAddr).get()])

  # await for network reachability with some timeout, 
  # to prevent waiting indefinitely
  await awaiter.wait(5.minutes)

  echo "Network reachability: ", service.networkReachability

  # if awaiter has completed then autonat tests has passed.
  return awaiter.completed()

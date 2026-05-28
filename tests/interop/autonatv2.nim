# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import net, chronos
import ../../libp2p/utils/future
import
  ../../libp2p/[
    builders,
    peerid,
    wire,
    protocols/connectivity/autonatv2/service,
    protocols/connectivity/autonatv2/types,
    services/natservice,
  ]
import ../tools/crypto

proc autonatInteropTest*(
    ourAddr: string,
    otherAddr: string,
    otherPeerId: PeerId,
    timeout: Duration = 5.minutes,
): Future[bool] {.async.} =
  var switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(@[MultiAddress.init(ourAddr).get()])
    .withAutonatV2Server()
    .withNAT(
      NATConfig(
        mode: Auto,
        autonat: Opt.some(AutonatV2),
        autonatV2ServiceConfig:
          Opt.some(AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds))),
      )
    )
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

  let awaiter = newFuture[void]()

  proc statusAndConfidenceHandler(
      networkReachability: NetworkReachability,
      confidence: Opt[float],
      dialBackAddr: Opt[MultiAddress],
  ) {.async: (raises: [CancelledError]).} =
    if networkReachability != NetworkReachability.Unknown and confidence.isSome() and
        confidence.get() >= 0.3:
      awaiter.completeOnce()

  var natService: NATService
  for s in switch.services:
    if s of NATService:
      natService = NATService(s)
      break
  doAssert natService != nil and natService.autonatV2Service != nil
  natService.autonatV2Service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

  await switch.start()
  defer:
    await switch.stop()
  await switch.connect(otherPeerId, @[MultiAddress.init(otherAddr).get()])

  # await for network reachability with some timeout,
  # to prevent waiting indefinitely
  await awaiter.wait(timeout)

  echo "Network reachability: ", natService.autonatV2Service.networkReachability

  # if awaiter has completed then autonat tests has passed.
  return awaiter.completed()

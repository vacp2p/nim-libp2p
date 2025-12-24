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
import ../../../../libp2p/protocols/connectivity/autonatv2/[service, types]

# Note: ipv6 is intentionally used here as it ensures ipv6 interop with other implementation.
const
  thisPeer = MultiAddress.init("/ip6/::1/tcp/3030").get()
  otherPeer = MultiAddress.init("/ip6/::1/tcp/4040").get()

proc main() {.async.} =
  if paramCount() != 1:
    quit("Usage: nim r src/nim_peer.nim <peerid>", 1)

  # ensure go peer has fully started
  await sleepAsync(3.seconds)

  let dstPeerId = PeerId.init(paramStr(1)).get()

  var src = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[thisPeer])
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
  await src.connect(dstPeerId, @[otherPeer])

  await awaiter
  echo service.networkReachability

when isMainModule:
  if waitFor(waitForService(otherPeer.getPart(1), Port(otherPeer.getPart(3)))):
    waitFor(main())
  else:
    quit("timeout waiting for service", 1)

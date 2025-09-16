import os, chronos, libp2p
import libp2p/protocols/connectivity/autonatv2/service
import libp2p/protocols/connectivity/autonatv2/types

proc main() {.async.} =
  if paramCount() != 1:
    quit("Usage: nimble run -- <peerid>", 1)

  let dstPeerId = PeerId.init(paramStr(1)).get()

  var src = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/3030").tryGet()], false)
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

  let service = cast[AutonatV2Service](src.services[0])
  service.setStatusAndConfidenceHandler(statusAndConfidenceHandler)

  await src.start()
  echo "connecting with peer " & $dstPeerId
  await src.connect(dstPeerId, @[MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get()])

  await awaiter
  echo service.networkReachability

waitFor(main())

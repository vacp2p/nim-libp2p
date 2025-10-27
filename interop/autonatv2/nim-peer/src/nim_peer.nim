import net, os, chronos, libp2p
import libp2p/protocols/connectivity/autonatv2/service
import libp2p/protocols/connectivity/autonatv2/types

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
    quit("Usage: nim r src/nim_peer.nim <peerid>", 1)

  # ensure go peer is started
  await sleepAsync(3.seconds)

  let dstPeerId = PeerId.init(paramStr(1)).get()

  var src = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/3030").tryGet()])
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
  await src.connect(dstPeerId, @[MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get()])

  await awaiter
  echo service.networkReachability

when isMainModule:
  if waitFor(waitForService("127.0.0.1", Port(4040))):
    waitFor(main())
  else:
    quit("timeout waiting for service", 1)

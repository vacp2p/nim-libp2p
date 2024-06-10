import std/[os, options, strformat, sequtils]
import redis
import chronos, chronicles
import
  ../../libp2p/[
    builders,
    switch,
    multicodec,
    observedaddrmanager,
    services/hpservice,
    services/autorelayservice,
    protocols/connectivity/autonat/client as aclient,
    protocols/connectivity/relay/client as rclient,
    protocols/connectivity/relay/relay,
    protocols/connectivity/autonat/service,
    protocols/ping,
  ]
import ../stubs/autonatclientstub
import ../errorhelpers

proc createSwitch(r: Relay = nil, hpService: Service = nil): Switch =
  let rng = newRng()
  var builder = SwitchBuilder
    .new()
    .withRng(rng)
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withObservedAddrManager(ObservedAddrManager.new(maxSize = 1, minCount = 1))
    .withTcpTransport({ServerFlags.TcpNoDelay})
    .withYamux()
    .withAutonat()
    .withNoise()

  if hpService != nil:
    builder = builder.withServices(@[hpService])

  if r != nil:
    builder = builder.withCircuitRelay(r)

  let s = builder.build()
  s.mount(Ping.new(rng = rng))
  return s

proc main() {.async.} =
  try:
    let relayClient = RelayClient.new()
    let autoRelayService = AutoRelayService.new(1, relayClient, nil, newRng())
    let autonatClientStub = AutonatClientStub.new(expectedDials = 1)
    autonatClientStub.answer = NotReachable
    let autonatService =
      AutonatService.new(autonatClientStub, newRng(), maxQueueSize = 1)
    let hpservice = HPService.new(autonatService, autoRelayService)

    let
      isListener = getEnv("MODE") == "listen"
      switch = createSwitch(relayClient, hpservice)
      auxSwitch = createSwitch()
      redisClient = open("redis", 6379.Port)

    debug "Connected to redis"

    await switch.start()
    await auxSwitch.start()

    let relayAddr =
      try:
        redisClient.bLPop(@["RELAY_TCP_ADDRESS"], 0)
      except Exception as e:
        raise newException(CatchableError, e.msg)

    # This is necessary to make the autonat service work. It will ask this peer for our reachability which the autonat
    # client stub will answer NotReachable.
    await switch.connect(auxSwitch.peerInfo.peerId, auxSwitch.peerInfo.addrs)

    # Wait for autonat to be NotReachable
    while autonatService.networkReachability != NetworkReachability.NotReachable:
      await sleepAsync(100.milliseconds)

    # This will trigger the autonat relay service to make a reservation.
    let relayMA = MultiAddress.init(relayAddr[1]).tryGet()
    debug "Got relay address", relayMA
    let relayId = await switch.connect(relayMA)
    debug "Connected to relay", relayId

    # Wait for our relay address to be published
    while not switch.peerInfo.addrs.anyIt(
      it.contains(multiCodec("p2p-circuit")).tryGet()
    )
    :
      await sleepAsync(100.milliseconds)

    if isListener:
      let listenerPeerId = switch.peerInfo.peerId
      discard redisClient.rPush("LISTEN_CLIENT_PEER_ID", $listenerPeerId)
      debug "Pushed listener client peer id to redis", listenerPeerId

      # Nothing to do anymore, wait to be killed
      await sleepAsync(2.minutes)
    else:
      let listenerId =
        try:
          PeerId.init(redisClient.bLPop(@["LISTEN_CLIENT_PEER_ID"], 0)[1]).tryGet()
        except Exception as e:
          raise newException(CatchableError, e.msg)

      debug "Got listener peer id", listenerId
      let listenerRelayAddr = MultiAddress.init($relayMA & "/p2p-circuit").tryGet()

      debug "Dialing listener relay address", listenerRelayAddr
      await switch.connect(listenerId, @[listenerRelayAddr])

      # wait for hole-punching to complete in the background
      await sleepAsync(5000.milliseconds)

      let conn = switch.connManager.selectMuxer(listenerId).connection
      let channel = await switch.dial(listenerId, @[listenerRelayAddr], PingCodec)
      let delay = await Ping.new().ping(channel)
      await allFuturesThrowing(
        channel.close(), conn.close(), switch.stop(), auxSwitch.stop()
      )
      echo &"""{{"rtt_to_holepunched_peer_millis":{delay.millis}}}"""
      quit(0)
  except CatchableError as e:
    error "Unexpected error", msg = e.msg

discard waitFor(main().withTimeout(4.minutes))
quit(1)

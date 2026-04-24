# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, os, sequtils, strformat, tables
import
  ../../libp2p/[
    builders,
    switch,
    multicodec,
    observedaddrmanager,
    services/hpservice,
    services/autorelayservice,
    protocols/connectivity/relay/client,
    protocols/connectivity/relay/relay,
    protocols/connectivity/autonat/service,
    protocols/ping,
  ]
import ../../tests/stubs/autonatclientstub
import ../unified_testing

logScope:
  topics = "hp interop peer"

type Config = object
  isDialer: bool
  bindIp: string
  redisAddr: string
  testKey: string
  transport: string
  secureChannel: string
  muxer: string

proc readConfig(): Config =
  let isDialer = getEnv("IS_DIALER") == "true"
  let bindIp =
    if isDialer:
      getEnv("DIALER_IP", "0.0.0.0")
    else:
      getEnv("LISTENER_IP", "0.0.0.0")

  let config = Config(
    isDialer: isDialer,
    bindIp: bindIp,
    redisAddr: getEnv("REDIS_ADDR", "redis:6379"),
    testKey: getEnv("TEST_KEY"),
    transport: getEnv("TRANSPORT", "tcp"),
    secureChannel: getEnv("SECURE_CHANNEL", "noise"),
    muxer: getEnv("MUXER", "mplex"),
  )
  info "Test configuration", config

  config

proc createSwitch(
    bindIp: string,
    transport: string,
    secureChannel: string,
    muxer: string,
    relayClient: Relay = nil,
    hpService: Service = nil,
): Switch =
  let rng = newRng()
  var builder = SwitchBuilder
    .new()
    .withRng(rng)
    .withObservedAddrManager(ObservedAddrManager.new(maxSize = 1, minCount = 1))
    .withAutonat()

  builder.addTransport(transport, bindIp, tcpFlags = {ServerFlags.TcpNoDelay})
  builder.addSecureChannel(secureChannel)
  builder.addMuxer(muxer)

  if hpService != nil:
    builder = builder.withServices(@[hpService])

  if relayClient != nil:
    builder = builder.withCircuitRelay(relayClient)

  let s = builder.build()
  s.mount(Ping.new(rng = rng))
  return s

proc isDirectlyConnected(switch: Switch, peerId: PeerId): bool =
  let conns = switch.connManager.getConnections()
  peerId in conns and conns[peerId].anyIt(not isRelayed(it.connection))

proc main() {.async.} =
  # Read test configuration
  let config = readConfig()

  # Setup relay
  let relayClient = RelayClient.new()
  let autoRelayService = AutoRelayService.new(1, relayClient, nil, newRng())

  # Setup autonat
  let autonatClientStub = AutonatClientStub.new(expectedDials = 1)
  autonatClientStub.answer = NotReachable

  # Setup hpservice
  let autonatService = AutonatService.new(autonatClientStub, newRng(), maxQueueSize = 1)
  let hpservice = HPService.new(autonatService, autoRelayService)

  # Setup switches
  let switch = createSwitch(
    config.bindIp, config.transport, config.secureChannel, config.muxer, relayClient,
    hpservice,
  )
  let auxSwitch =
    createSwitch(config.bindIp, config.transport, config.secureChannel, config.muxer)

  await allFutures(switch.start(), auxSwitch.start())
  defer:
    # Timeout the stop to avoid hanging on mplex teardown
    discard await allFutures(switch.stop(), auxSwitch.stop()).withTimeout(5.seconds)

  # Connect to aux switch for AutoNAT stub to report NotReachable
  await switch.connect(auxSwitch.peerInfo.peerId, auxSwitch.peerInfo.addrs)

  # Wait for autonat to report NotReachable
  pollUntil(
    autonatService.networkReachability == NetworkReachability.NotReachable,
    errorMsg = "Timeout waiting for AutoNAT NotReachable",
  )
  info "AutoNAT reports NotReachable"

  # Get relay multiaddr from Redis (set by Rust relay)
  let redisClient = setupRedis(config.redisAddr)
  let relayAddr = await redisClient.pollGet(&"{config.testKey}_relay_multiaddr")
  info "Got relay address", relayAddr

  # Connect to relay (triggers AutoRelay reservation)
  let relayMA = MultiAddress.init(relayAddr).tryGet()
  try:
    info "Dialing relay", relayMA
    let relayId = await switch.connect(relayMA).wait(30.seconds)
    info "Connected to relay", relayId
  except AsyncTimeoutError as e:
    raise newException(CatchableError, "Connection to relay timed out: " & e.msg, e)

  # Wait for our relay circuit address
  pollUntil(
    switch.peerInfo.addrs.anyIt(it.contains(multiCodec("p2p-circuit")).tryGet()),
    errorMsg = "Timeout waiting for relay circuit address",
  )
  info "Got relay circuit address"

  if config.isDialer:
    # Get listener peer ID from Redis
    let listenerPeerIdStr =
      await redisClient.pollGet(&"{config.testKey}_listener_peer_id")
    let listenerId = PeerId.init(listenerPeerIdStr).tryGet()
    info "Got listener peer ID", listenerId

    let listenerRelayAddr = MultiAddress.init($relayMA & "/p2p-circuit").tryGet()

    # Start DCUtR timer
    let dcutrStart = Moment.now()

    info "Dialing listener via relay", listenerRelayAddr
    await switch.connect(listenerId, @[listenerRelayAddr])

    # Wait for DCUtR to complete (direct connection established)
    # HPService handles DCUtR in the background when the listener receives
    # the relayed connection. Poll for a direct connection.
    pollUntil(
      switch.isDirectlyConnected(listenerId),
      errorMsg = "DCUtR failed: no direct connection established within timeout",
    )

    let dcutrElapsed = Moment.now() - dcutrStart
    info "Direct connection established via DCUtR"

    # Ping over the direct connection
    let channel = await switch.dial(listenerId, PingCodec)
    defer:
      await channel.close()

    let pingDelay = await Ping.new().ping(channel)
    let pingRttMs = pingDelay.toMs()

    let handshakePlusOneRtt = dcutrElapsed.toMs() + pingRttMs

    # Output YAML to stdout
    echo "latency:"
    echo &"  handshake_plus_one_rtt: {handshakePlusOneRtt:.2f}"
    echo &"  ping_rtt: {pingRttMs:.2f}"
    echo "  unit: ms"
  else:
    # Listener: publish peer ID to Redis and wait
    let listenerPeerId = $switch.peerInfo.peerId
    redisClient.setk(&"{config.testKey}_listener_peer_id", listenerPeerId)
    info "Published listener peer ID to Redis", listenerPeerId

    # Wait to be killed (docker-compose will stop us after dialer exits)
    await sleepAsync(5.minutes)

runMain(4.minutes):
  await main()

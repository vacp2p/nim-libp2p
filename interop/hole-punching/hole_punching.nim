# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/os, chronos, chronicles, sequtils, tables
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

proc createSwitch(
    config: BaseConfig, relayClient: Relay = nil, hpService: Service = nil
): Switch =
  var s = buildBaseSwitch(config, tcpFlags = {ServerFlags.TcpNoDelay})
    .withObservedAddrManager(ObservedAddrManager.new(maxSize = 1, minCount = 1))
    .withAutonat()
    .withCircuitRelay(relayClient)
    .build()

  s.add(hpService)
  s.mount(Ping.new(rng = rng()))
  s

proc isDirectlyConnected(switch: Switch, peerId: PeerId): bool =
  let conns = switch.connManager.getConnections()
  peerId in conns and conns[peerId].anyIt(not isRelayed(it.connection))

type HolePunchSwitches = object
  sw: Switch
  autonatService: AutonatService
  autoRelayService: AutoRelayService

proc createSwitches(config: BaseConfig): HolePunchSwitches =
  # Setup relay
  let relayClient = RelayClient.new()
  let autoRelayService = AutoRelayService.new(1, relayClient, nil, rng())

  # Setup autonat
  let autonatClientStub = AutonatClientStub.new(expectedDials = 1)
  autonatClientStub.answer = NotReachable

  # Setup hpservice
  let autonatService = AutonatService.new(autonatClientStub, rng(), maxQueueSize = 1)
  let hpservice = HPService.new(autonatService, autoRelayService)

  # Setup switches
  let switches = HolePunchSwitches(
    sw: createSwitch(config, relayClient, hpservice),
    autonatService: autonatService,
    autoRelayService: autoRelayService,
  )
  switches

proc connectToRelay(
    config: BaseConfig, redisClient: Redis, switches: HolePunchSwitches
): Future[MultiAddress] {.async.} =
  # The Docker v2 harness already places the peer behind a NAT router. Avoid
  # the synthetic in-process AutoNAT probe and mark the node as private before
  # reserving through the relay.
  switches.autonatService.networkReachability = NetworkReachability.NotReachable
  for t in switches.sw.transports:
    t.networkReachability = NetworkReachability.NotReachable
  await switches.autoRelayService.start(switches.sw)
  info "AutoNAT forced to NotReachable; AutoRelay started"

  # Connect to relay (triggers AutoRelay reservation)
  let relayMA = await fetchRelayMultiaddr(redisClient, config)
  info "Got relay address", relayMA

  try:
    info "Dialing relay", relayMA
    let relayId = await switches.sw.connect(relayMA).wait(30.seconds)
    info "Connected to relay", relayId
  except AsyncTimeoutError as e:
    raise newException(CatchableError, "Connection to relay timed out: " & e.msg, e)

  # Wait for our relay circuit address
  pollUntil(
    switches.sw.peerInfo.addrs.anyIt(it.contains(multiCodec("p2p-circuit")).tryGet()),
    errorMsg = "Timeout waiting for relay circuit address",
  )
  info "Got relay circuit address"
  relayMA

proc runDialer(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    switches = createSwitches(config)

  await switches.sw.start()
  defer:
    # Timeout the stop to avoid hanging on mplex teardown
    discard await switches.sw.stop().withTimeout(5.seconds)

  let relayMA = await connectToRelay(config, redisClient, switches)

  let listenerId = await fetchListenerPeerId(redisClient, config.testKey)
  info "Got listener peer ID", listenerId

  let listenerRelayAddr = MultiAddress.init($relayMA & "/p2p-circuit").tryGet()

  # Start DCUtR timer
  let dcutrStart = Moment.now()

  info "Dialing listener via relay", listenerRelayAddr
  await switches.sw.connect(listenerId, @[listenerRelayAddr])

  # Wait for DCUtR to complete (direct connection established)
  # HPService handles DCUtR in the background when the listener receives
  # the relayed connection. Poll for a direct connection.
  pollUntil(
    switches.sw.isDirectlyConnected(listenerId),
    errorMsg = "DCUtR failed: no direct connection established within timeout",
  )

  let dcutrElapsed = Moment.now() - dcutrStart
  info "Direct connection established via DCUtR", elapsed = dcutrElapsed

  # Ping over the direct connection
  let channel = await switches.sw.dial(listenerId, PingCodec)
  defer:
    await channel.close()

  let pingDelay = await Ping.new(rng = rng()).ping(channel)
  let pingRttMs = pingDelay.toMs()

  printHolePunchReportJson(pingRttMs)

proc runListener(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    switches = createSwitches(config)

  await switches.sw.start()
  defer:
    # Timeout the stop to avoid hanging on mplex teardown
    discard await switches.sw.stop().withTimeout(5.seconds)

  discard await connectToRelay(config, redisClient, switches)

  let listenerPeerId = publishListenerPeerId(redisClient, config.testKey, switches.sw)
  info "Published listener peer ID to Redis", listenerPeerId

  # Wait to be killed (docker-compose will stop us after dialer exits)
  await sleepAsync(5.minutes)

proc main() {.async.} =
  var config = readBaseConfig()
  if getEnv("MUXER").len == 0:
    config.muxer = "yamux"
  info "Test configuration", config
  if config.isDialer:
    await runDialer(config)
  else:
    await runListener(config)

let testTimeout = parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout)
runMain(main, testTimeout)

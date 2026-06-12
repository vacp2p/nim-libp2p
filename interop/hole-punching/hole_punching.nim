# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, strformat]

import chronos, chronicles, sequtils, tables
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

const
  ListenMode = "listen"
  DialMode = "dial"
  ListenClientPeerIdKey = "LISTEN_CLIENT_PEER_ID"
  RelayTcpAddressKey = "RELAY_TCP_ADDRESS"
  RelayQuicAddressKey = "RELAY_QUIC_ADDRESS"

proc normalizeTransport(transport: string): string =
  if transport == "quic": "quic-v1" else: transport

proc readHolePunchConfig(): BaseConfig =
  let
    mode = getEnv("MODE")
    isDialer =
      case mode
      of DialMode:
        true
      of ListenMode:
        false
      of "":
        parseBoolEnv("IS_DIALER", false)
      else:
        raise newException(CatchableError, "unsupported MODE: " & mode)
    transport = normalizeTransport(getEnv("TRANSPORT", "tcp"))
    bindIp =
      if isDialer:
        resolveBindIp(getEnv("DIALER_IP", getEnv("LISTENER_IP", "0.0.0.0")))
      else:
        resolveBindIp(getEnv("LISTENER_IP", "0.0.0.0"))

  BaseConfig(
    isDialer: isDialer,
    bindIp: bindIp,
    redisAddr: getEnv("REDIS_ADDR", "redis:6379"),
    testKey: getEnv("TEST_KEY", ""),
    transport: transport,
    # Circuit-relayed connections still need an inner upgrade over QUIC.
    secureChannel: getEnv("SECURE_CHANNEL", "noise"),
    muxer: getEnv("MUXER", "yamux"),
    testTimeout: parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout),
  )

proc relayAddressKey(config: BaseConfig): string =
  case config.transport
  of "tcp":
    RelayTcpAddressKey
  of "quic-v1":
    RelayQuicAddressKey
  else:
    raise newException(CatchableError, "unsupported transport: " & config.transport)

proc popRedisListValue(client: Redis, key: string, timeout: Duration): string =
  try:
    client.bLPop(@[key], timeout.seconds.int)[1]
  except Exception as e:
    raise newException(
      CatchableError, "Exception calling bLPop for " & key & ": " & e.msg, e
    )

proc fetchHolePunchRelayMultiaddr(
    client: Redis, config: BaseConfig, timeout: Duration = 30.seconds
): Future[MultiAddress] {.async.} =
  let raw = client.popRedisListValue(relayAddressKey(config), timeout)
  MultiAddress.init(raw).tryGet()

proc publishHolePunchListenerPeerId(client: Redis, sw: Switch): PeerId =
  let peerId = sw.peerInfo.peerId
  discard client.rPush(ListenClientPeerIdKey, $peerId)
  peerId

proc fetchHolePunchListenerPeerId(
    client: Redis, timeout: Duration = 30.seconds
): Future[PeerId] {.async.} =
  let raw = client.popRedisListValue(ListenClientPeerIdKey, timeout)
  PeerId.init(raw).tryGet()

proc printRttJson(rttMs: float) =
  echo &"""{{"rtt_to_holepunched_peer_millis":{rttMs:.2f}}}"""

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
  aux: Switch
  autonatService: AutonatService

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
    aux: createSwitch(config),
    autonatService: autonatService,
  )
  switches

proc connectToRelay(
    config: BaseConfig, redisClient: Redis, switches: HolePunchSwitches
): Future[MultiAddress] {.async.} =
  # Connect to aux switch for AutoNAT stub to report NotReachable
  await switches.sw.connect(switches.aux.peerInfo.peerId, switches.aux.peerInfo.addrs)

  # Wait for autonat to report NotReachable
  pollUntil(
    switches.autonatService.networkReachability == NetworkReachability.NotReachable,
    config.testTimeout,
    200.milliseconds,
    errorMsg = "Timeout waiting for AutoNAT NotReachable",
  )
  info "AutoNAT reports NotReachable"

  # Connect to relay (triggers AutoRelay reservation)
  let relayMA =
    await fetchHolePunchRelayMultiaddr(redisClient, config, config.testTimeout)
  info "Got relay address", relayMA

  try:
    info "Dialing relay", relayMA
    let relayId = await switches.sw.connect(relayMA).wait(config.testTimeout)
    info "Connected to relay", relayId
  except AsyncTimeoutError as e:
    raise newException(CatchableError, "Connection to relay timed out: " & e.msg, e)

  # Wait for our relay circuit address
  pollUntil(
    switches.sw.peerInfo.addrs.anyIt(it.contains(multiCodec("p2p-circuit")).tryGet()),
    config.testTimeout,
    200.milliseconds,
    errorMsg = "Timeout waiting for relay circuit address",
  )
  info "Got relay circuit address"
  relayMA

proc runDialer(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    switches = createSwitches(config)

  await allFutures(switches.sw.start(), switches.aux.start())
  defer:
    # Timeout the stop to avoid hanging on mplex teardown
    discard
      await allFutures(switches.sw.stop(), switches.aux.stop()).withTimeout(5.seconds)

  let relayMA = await connectToRelay(config, redisClient, switches)
  let listenerId = await fetchHolePunchListenerPeerId(redisClient, config.testTimeout)
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
    config.testTimeout,
    200.milliseconds,
    errorMsg = "DCUtR failed: no direct connection established within timeout",
  )

  let dcutrElapsed = Moment.now() - dcutrStart
  info "Direct connection established via DCUtR", elapsedMs = dcutrElapsed.toMs()

  # Ping over the direct connection
  let channel = await switches.sw.dial(listenerId, PingCodec)
  defer:
    await channel.close()

  let pingDelay = await Ping.new(rng = rng()).ping(channel)
  printRttJson(pingDelay.toMs())

proc runListener(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    switches = createSwitches(config)

  await allFutures(switches.sw.start(), switches.aux.start())
  defer:
    # Timeout the stop to avoid hanging on mplex teardown
    discard
      await allFutures(switches.sw.stop(), switches.aux.stop()).withTimeout(5.seconds)

  discard await connectToRelay(config, redisClient, switches)

  let listenerPeerId = publishHolePunchListenerPeerId(redisClient, switches.sw)
  info "Published listener peer ID to Redis", listenerPeerId

  # Wait to be killed (docker-compose will stop us after dialer exits)
  await sleepAsync(config.testTimeout)

proc main() {.async.} =
  let config = readHolePunchConfig()
  info "Test configuration", config
  if config.isDialer:
    await runDialer(config)
  else:
    await runListener(config)

let testTimeout = parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout)
runMain(main, testTimeout)

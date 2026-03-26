# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, strutils, strformat, sequtils]
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
    transports/wstransport,
  ]
import ../../tests/stubs/autonatclientstub

logScope:
  topics = "hp interop peer"

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

  # Transport selection
  case transport
  of "tcp":
    discard builder.withTcpTransport({ServerFlags.TcpNoDelay}).withAddress(
        MultiAddress.init("/ip4/" & bindIp & "/tcp/0").tryGet()
      )
  of "ws":
    discard builder.withWsTransport().withAddress(
        MultiAddress.init("/ip4/" & bindIp & "/tcp/0/ws").tryGet()
      )
  of "quic-v1":
    discard builder.withQuicTransport().withAddress(
        MultiAddress.init("/ip4/" & bindIp & "/udp/0/quic-v1").tryGet()
      )
  else:
    raiseAssert "unsupported transport: " & transport

  # Secure channel selection (not used for QUIC)
  case secureChannel
  of "noise":
    discard builder.withNoise()
  of "":
    discard # QUIC doesn't need a separate secure channel
  else:
    raiseAssert "unsupported secure channel: " & secureChannel

  # Muxer selection (not used for QUIC)
  case muxer
  of "yamux":
    discard builder.withYamux()
  of "mplex":
    discard builder.withMplex()
  of "":
    discard # QUIC doesn't need a separate muxer
  else:
    raiseAssert "unsupported muxer: " & muxer

  if hpService != nil:
    builder = builder.withServices(@[hpService])

  if relayClient != nil:
    builder = builder.withCircuitRelay(relayClient)

  let s = builder.build()
  s.mount(Ping.new(rng = rng))
  return s

proc redisGet(client: Redis, key: string, maxRetries: int = 300, delayMs: int = 500): string =
  ## Poll Redis for a key with retries (GET with polling, not BLPOP)
  for i in 0 ..< maxRetries:
    let val = client.get(key)
    if val != redisNil and val.len > 0:
      return val
    sleep(delayMs)
  raise newException(CatchableError, "Timeout waiting for Redis key: " & key)

proc main() {.async.} =
  # Read environment variables (uppercase, modern convention)
  let
    isDialer = getEnv("IS_DIALER") == "true"
    redisAddrStr = getEnv("REDIS_ADDR", "redis:6379")
    testKey = getEnv("TEST_KEY")
    transport = getEnv("TRANSPORT", "tcp")
    secureChannel = getEnv("SECURE_CHANNEL", "")
    muxer = getEnv("MUXER", "")
    debug = getEnv("DEBUG", "false") == "true"

  let bindIp =
    if isDialer:
      getEnv("DIALER_IP", "0.0.0.0")
    else:
      getEnv("LISTENER_IP", "0.0.0.0")

  stderr.writeLine &"IS_DIALER: {isDialer}"
  stderr.writeLine &"REDIS_ADDR: {redisAddrStr}"
  stderr.writeLine &"TEST_KEY: {testKey}"
  stderr.writeLine &"TRANSPORT: {transport}"
  stderr.writeLine &"SECURE_CHANNEL: {secureChannel}"
  stderr.writeLine &"MUXER: {muxer}"
  stderr.writeLine &"BIND_IP: {bindIp}"

  # Parse Redis address
  let redisAddr = redisAddrStr.split(":")
  let redisHost = redisAddr[0]
  let redisPort = Port(parseInt(redisAddr[1]))

  # Setup relay + autonat + hpservice
  let relayClient = RelayClient.new()
  let autoRelayService = AutoRelayService.new(1, relayClient, nil, newRng())
  let autonatClientStub = AutonatClientStub.new(expectedDials = 1)
  autonatClientStub.answer = NotReachable
  let autonatService = AutonatService.new(autonatClientStub, newRng(), maxQueueSize = 1)
  let hpservice = HPService.new(autonatService, autoRelayService)

  let
    switch = createSwitch(bindIp, transport, secureChannel, muxer, relayClient, hpservice)
    auxSwitch = createSwitch(bindIp, transport, secureChannel, muxer)
    redisClient = open(redisHost, redisPort)

  stderr.writeLine "Connected to Redis"

  await switch.start()
  await auxSwitch.start()

  # Poll relay multiaddr from Redis (set by Rust relay)
  let relayAddrStr = redisGet(redisClient, &"{testKey}_relay_multiaddr")
  stderr.writeLine &"Got relay address: {relayAddrStr}"

  # Connect to aux switch for AutoNAT stub to report NotReachable
  await switch.connect(auxSwitch.peerInfo.peerId, auxSwitch.peerInfo.addrs)

  # Wait for autonat to report NotReachable
  while autonatService.networkReachability != NetworkReachability.NotReachable:
    await sleepAsync(100.milliseconds)
  stderr.writeLine "AutoNAT reports NotReachable"

  # Connect to relay (triggers AutoRelay reservation)
  let relayMA = MultiAddress.init(relayAddrStr).tryGet()
  try:
    stderr.writeLine &"Dialing relay: {relayMA}"
    let relayId = await switch.connect(relayMA).wait(30.seconds)
    stderr.writeLine &"Connected to relay: {relayId}"
  except AsyncTimeoutError as e:
    raise newException(CatchableError, "Connection to relay timed out: " & e.msg, e)

  # Wait for our relay circuit address
  while not switch.peerInfo.addrs.anyIt(it.contains(multiCodec("p2p-circuit")).tryGet()):
    await sleepAsync(100.milliseconds)
  stderr.writeLine "Got relay circuit address"

  if isDialer:
    # Poll listener peer ID from Redis
    let listenerPeerIdStr = redisGet(redisClient, &"{testKey}_listener_peer_id", maxRetries = 30)
    let listenerId = PeerId.init(listenerPeerIdStr).tryGet()
    stderr.writeLine &"Got listener peer ID: {listenerId}"

    let listenerRelayAddr = MultiAddress.init($relayMA & "/p2p-circuit").tryGet()

    # Start DCUtR timer
    let dcutrStart = Moment.now()

    stderr.writeLine &"Dialing listener via relay: {listenerRelayAddr}"
    await switch.connect(listenerId, @[listenerRelayAddr])

    # Wait for DCUtR to complete (direct connection established)
    # HPService handles DCUtR in the background when the listener receives
    # the relayed connection. Poll for a direct (non-relayed) connection.
    var directConnEstablished = false
    for i in 0 ..< 600: # 60 seconds max
      let conns = switch.connManager.getConnections()
      if listenerId in conns:
        let muxers = conns[listenerId]
        if muxers.anyIt(not isRelayed(it.connection)):
          directConnEstablished = true
          break
      await sleepAsync(100.milliseconds)

    let dcutrElapsed = Moment.now() - dcutrStart

    if not directConnEstablished:
      raise newException(CatchableError, "DCUtR failed: no direct connection established within timeout")

    stderr.writeLine "Direct connection established via DCUtR"

    # Ping over the direct connection
    let channel = await switch.dial(listenerId, @[listenerRelayAddr], PingCodec)
    let pingDelay = await Ping.new().ping(channel)
    await channel.close()

    let pingRttMs = float(pingDelay.milliseconds)
    let handshakePlusOneRtt = float(dcutrElapsed.milliseconds) + pingRttMs

    # Output YAML to stdout (only stdout, all logging goes to stderr)
    echo "latency:"
    echo &"  handshake_plus_one_rtt: {handshakePlusOneRtt:.2f}"
    echo &"  ping_rtt: {pingRttMs:.2f}"
    echo "  unit: ms"

    # Timeout the stop to avoid hanging on mplex teardown
    discard await allFutures(switch.stop(), auxSwitch.stop()).withTimeout(30.seconds)
  else:
    # Listener: publish peer ID to Redis and wait
    let listenerPeerId = $switch.peerInfo.peerId
    redisClient.setk(&"{testKey}_listener_peer_id", listenerPeerId)
    stderr.writeLine &"Published listener peer ID to Redis: {listenerPeerId}"

    # Wait to be killed (docker-compose will stop us after dialer exits)
    await sleepAsync(5.minutes)

try:
  proc mainAsync(): Future[string] {.async.} =
    await main()
    return "done"

  discard waitFor(mainAsync().wait(4.minutes))
except AsyncTimeoutError as e:
  error "Program execution timed out", description = e.msg
  quit(-1)
except CatchableError as e:
  error "Unexpected error", description = e.msg
  quit(-1)

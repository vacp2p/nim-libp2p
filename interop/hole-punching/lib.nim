# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, redis, os, strutils, sequtils, tables
import
  ../../libp2p/[
    builders,
    switch,
    multicodec,
    observedaddrmanager,
    protocols/connectivity/relay/relay,
    protocols/ping,
  ]

logScope:
  topics = "hp interop peer"

type Config* = object
  isDialer*: bool
  bindIp*: string
  redisAddr*: string
  testKey*: string
  transport*: string
  secureChannel*: string
  muxer*: string

proc readConfig*(): Config =
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

proc createSwitch*(
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
  else:
    raiseAssert "unsupported transport: " & transport

  # Secure channel selection
  case secureChannel
  of "noise":
    discard builder.withNoise()
  else:
    raiseAssert "unsupported secure channel: " & secureChannel

  # Muxer selection
  case muxer
  of "yamux":
    discard builder.withYamux()
  of "mplex":
    discard builder.withMplex()
  else:
    raiseAssert "unsupported muxer: " & muxer

  if hpService != nil:
    builder = builder.withServices(@[hpService])

  if relayClient != nil:
    builder = builder.withCircuitRelay(relayClient)

  let s = builder.build()
  s.mount(Ping.new(rng = rng))
  return s

proc setupRedis*(config: Config): Redis =
  let redisAddr = config.redisAddr.split(":")
  let redisHost = redisAddr[0]
  let redisPort = Port(parseInt(redisAddr[1]))

  let redisClient = open(redisHost, redisPort)
  info "Connected to Redis"

  redisClient

proc isDirectlyConnected*(switch: Switch, peerId: PeerId): bool =
  let conns = switch.connManager.getConnections()
  peerId in conns and conns[peerId].anyIt(not isRelayed(it.connection))

template pollUntil*(
    condition: untyped,
    timeout: Duration = 30.seconds,
    delay: Duration = 200.milliseconds,
    errorMsg: string = "Timeout waiting for condition",
) =
  let deadline = Moment.now() + timeout
  while true:
    if condition:
      break
    if Moment.now() >= deadline:
      raise newException(CatchableError, errorMsg)
    await sleepAsync(delay)

proc pollGet*(client: Redis, key: string): Future[string] {.async.} =
  var val: string
  proc hasValue(): bool =
    val = client.get(key)
    val != redisNil and val.len > 0

  pollUntil(
    hasValue(), 30.seconds, 500.milliseconds, "Timeout waiting for Redis key: " & key
  )
  return val

proc toMs*(duration: Duration): float =
  float(duration.microseconds()) / 1_000.0

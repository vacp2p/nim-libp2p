# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Shared helpers for libp2p unified-testing interop binaries.

import std/[os, sequtils, strformat, strutils]
import chronos, chronicles, redis
import ../libp2p/[builders, transports/wstransport]
import ../tests/tools/crypto

export redis, crypto

# ---------- config ----------

type BaseConfig* = object of RootObj
  ## Shared configuration for unified-testing interop binaries.
  isDialer*: bool
  bindIp*: string
  redisAddr*: string
  testKey*: string
  transport*: string
  secureChannel*: string
  muxer*: string
  testTimeout*: Duration

const DefaultTestTimeout* = 600.seconds

proc readBaseConfig*(): BaseConfig =
  let isDialer = parseBoolEnv("IS_DIALER", false)
  let bindIp =
    if isDialer:
      resolveBindIp(getEnv("DIALER_IP", getEnv("LISTENER_IP", "0.0.0.0")))
    else:
      resolveBindIp(getEnv("LISTENER_IP", "0.0.0.0"))
  let config = BaseConfig(
    isDialer: isDialer,
    bindIp: bindIp,
    redisAddr: getEnv("REDIS_ADDR", "redis:6379"),
    testKey: getEnv("TEST_KEY"),
    transport: getEnv("TRANSPORT", "tcp"),
    secureChannel: getEnv("SECURE_CHANNEL", "noise"),
    muxer: getEnv("MUXER", "mplex"),
    testTimeout: parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout),
  )
  config

proc parseBoolEnv*(name: string, defaultValue: bool): bool =
  getEnv(name, $defaultValue).toLowerAscii() == "true"

proc parseIntEnv*(name: string, defaultValue: int): int =
  try:
    parseInt(getEnv(name, $defaultValue))
  except ValueError:
    defaultValue

proc parseUint64Env*(name: string, defaultValue: uint64): uint64 =
  try:
    uint64(parseBiggestUInt(getEnv(name, $defaultValue)))
  except ValueError:
    defaultValue

proc parseDurationEnv*(name: string, unit: Duration, defaultValue: Duration): Duration =
  let raw = getEnv(name)
  if raw.len == 0:
    return defaultValue
  try:
    parseInt(raw) * unit
  except ValueError:
    defaultValue

proc resolveBindIp*(ip: string): string =
  ## If `ip` is the wildcard 0.0.0.0, pick the first eth0 address
  ## (the docker-compose network the interop harness wires up). Otherwise
  ## return `ip` unchanged.
  if ip != "0.0.0.0":
    return ip

  let addresses = getInterfaces().filterIt(it.name == "eth0").mapIt(it.addresses)
  if addresses.len < 1 or addresses[0].len < 1:
    raise newException(CatchableError, "Can't find local ip!")

  ($addresses[0][0].host).split(":")[0]

# ---------- redis ----------

proc setupRedis*(redisAddr: string): Redis =
  let parts = redisAddr.split(":")
  if parts.len != 2:
    raise
      newException(CatchableError, "REDIS_ADDR must be host:port, got: " & redisAddr)
  let port =
    try:
      Port(parseInt(parts[1]))
    except ValueError as e:
      raise newException(CatchableError, "Invalid REDIS_ADDR port: " & parts[1], e)
  open(parts[0], port)

template pollUntil*(
    condition: untyped,
    timeout: Duration = 30.seconds,
    delay: Duration = 200.milliseconds,
    errorMsg: string = "Timeout waiting for condition",
) =
  ## Poll `condition` until it becomes true or `timeout` elapses.
  ## Raises `CatchableError(errorMsg)` on timeout.
  let deadline = Moment.now() + timeout
  while true:
    if condition:
      break
    if Moment.now() >= deadline:
      raise newException(CatchableError, errorMsg)
    await sleepAsync(delay)

proc pollGet*(
    client: Redis,
    key: string,
    timeout: Duration = 30.seconds,
    delay: Duration = 500.milliseconds,
): Future[string] {.async.} =
  ## Poll a Redis key until it contains a non-empty value or `timeout` elapses.
  var val: string
  proc hasValue(): bool =
    val = client.get(key)
    val != redisNil and val.len > 0

  pollUntil(hasValue(), timeout, delay, "Timeout waiting for Redis key: " & key)
  return val

const
  ListenerMultiaddrSuffix* = "_listener_multiaddr"
  ListenerPeerIdSuffix* = "_listener_peer_id"
  RelayMultiaddrSuffix* = "_relay_multiaddr"

proc makeKey*(testKey, suffix: string): string =
  testKey & suffix

proc publishValue*(client: Redis, testKey, suffix, value: string) =
  client.setk(makeKey(testKey, suffix), value)

proc fetchValue*(
    client: Redis, testKey, suffix: string, timeout: Duration = 30.seconds
): Future[string] {.async.} =
  await client.pollGet(makeKey(testKey, suffix), timeout)

proc publishListenerMultiaddr*(client: Redis, testKey: string, sw: Switch) =
  let addrs = sw.peerInfo.fullAddrs.tryGet()
  if addrs.len == 0:
    raise newException(CatchableError, "Listener has no addresses")
  client.publishValue(testKey, ListenerMultiaddrSuffix, $addrs[0])

proc fetchListenerMultiaddr*(
    client: Redis, testKey: string, timeout: Duration = 30.seconds
): Future[MultiAddress] {.async.} =
  let raw = await client.fetchValue(testKey, ListenerMultiaddrSuffix, timeout)
  MultiAddress.init(raw).tryGet()

proc publishListenerPeerId*(client: Redis, testKey: string, sw: Switch): PeerId =
  let peerId = sw.peerInfo.peerId
  client.publishValue(testKey, ListenerPeerIdSuffix, $peerId)
  peerId

proc fetchListenerPeerId*(
    client: Redis, testKey: string, timeout: Duration = 30.seconds
): Future[PeerId] {.async.} =
  let raw = await client.fetchValue(testKey, ListenerPeerIdSuffix, timeout)
  PeerId.init(raw).tryGet()

proc fetchRelayMultiaddr*(
    client: Redis, testKey: string, timeout: Duration = 30.seconds
): Future[MultiAddress] {.async.} =
  let raw = await client.fetchValue(testKey, RelayMultiaddrSuffix, timeout)
  MultiAddress.init(raw).tryGet()

# ---------- timing ----------

proc toMs*(duration: Duration): float =
  float(duration.microseconds()) / 1_000.0

proc printLatencyYaml*(handshakePlusOneRttMs, pingRttMs: float) =
  echo "latency:"
  echo &"  handshake_plus_one_rtt: {handshakePlusOneRttMs:.2f}"
  echo &"  ping_rtt: {pingRttMs:.2f}"
  echo "  unit: ms"

# ---------- switch builder dispatch ----------

proc addTransport*(
    builder: SwitchBuilder,
    transport: string,
    bindIp: string,
    tcpFlags: set[ServerFlags] = {},
) =
  ## Wire up `transport` + its listen address on `builder`.
  ## Supports `tcp`, `ws`, `quic-v1`. Raises `CatchableError` on unknown values.
  case transport
  of "tcp":
    discard builder.withTcpTransport(tcpFlags).withAddress(
        MultiAddress.init("/ip4/" & bindIp & "/tcp/0").tryGet()
      )
  of "ws":
    discard builder.withWsTransport(flags = tcpFlags).withAddress(
        MultiAddress.init("/ip4/" & bindIp & "/tcp/0/ws").tryGet()
      )
  of "quic-v1":
    discard builder.withQuicTransport().withAddress(
        MultiAddress.init("/ip4/" & bindIp & "/udp/0/quic-v1").tryGet()
      )
  else:
    raise newException(CatchableError, "unsupported transport: " & transport)

proc addSecureChannel*(builder: SwitchBuilder, secureChannel: string) =
  ## Add a secure-channel upgrade. Accepts `noise`. Accepts empty string and
  ## literal `"null"` as no-ops (standalone transports like quic-v1 provide
  ## their own security).
  case secureChannel
  of "noise":
    discard builder.withNoise()
  of "", "null":
    discard
  else:
    raise newException(CatchableError, "unsupported secure channel: " & secureChannel)

proc addMuxer*(builder: SwitchBuilder, muxer: string) =
  ## Add a stream multiplexer. Accepts `yamux`, `mplex`. Accepts empty string
  ## and literal `"null"` as no-ops.
  case muxer
  of "yamux":
    discard builder.withYamux()
  of "mplex":
    discard builder.withMplex()
  of "", "null":
    discard
  else:
    raise newException(CatchableError, "unsupported muxer: " & muxer)

proc buildBaseSwitch*[T: BaseConfig](
    config: T, tcpFlags: set[ServerFlags] = {}
): SwitchBuilder =
  var builder = SwitchBuilder.new().withRng(rng())
  builder.addTransport(config.transport, config.bindIp, tcpFlags = tcpFlags)
  builder.addSecureChannel(config.secureChannel)
  builder.addMuxer(config.muxer)
  builder

# ---------- runner ----------

template runMain*(timeout: Duration, body: untyped) =
  ## Run `body` as the async entry point of an interop test binary:
  ##  - wrap in a chronos proc (so can be `await`ed),
  ##  - bound by `timeout`,
  ##  - log and `quit(-1)` on timeout or any `CatchableError`,
  ##  - returns value, as otherwise 'waitFor(fut)' has no type (or is ambiguous).
  try:
    proc interopMainAsync(): Future[string] {.async.} =
      body
      return "done"

    discard waitFor(interopMainAsync().wait(timeout))
  except AsyncTimeoutError as e:
    error "Program execution timed out", description = e.msg
    quit(-1)
  except CatchableError as e:
    error "Unexpected error", description = e.msg
    quit(-1)

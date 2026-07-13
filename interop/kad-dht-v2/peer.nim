# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Unified-testing kad-dht interop peer.
##
## One binary implements all three roles the `kad-dht/` harness wires up via the
## `ROLE` env var (bootstrap | provider | querier). The harness passes only
## `ROLE`, `REDIS_ADDR`, and `TEST_KEY`; the transport is fixed to tcp/noise/yamux.
##
## Contract (mirrors kad-dht/images/py/node.py and images/dotnet/Program.cs):
##   - bootstrap: publish own multiaddr to Redis `{TEST_KEY}_bootstrap_addr`, stay up
##   - provider:  connect to bootstrap, addProvider + putValue, set `{TEST_KEY}_provider_done`
##   - querier:   wait for both keys, connect, getProviders + getValue, print `status: pass`

import std/[os, sets, strutils]
import chronos, chronicles, stew/byteutils
import ../../libp2p/[builders, switch, peerid]
import ../../libp2p/protocols/kademlia
import ../unified_testing

logScope:
  topics = "kad-dht interop"

const
  # Redis key suffixes agreed with the py/dotnet nodes.
  BootstrapAddrSuffix = "_bootstrap_addr"
  ProviderDoneSuffix = "_provider_done"
  # Value announced by the provider and checked (substring) by the querier.
  ProviderValue = "hello from nim client"
  # Retry budget for the querier's DHT lookups: propagation in a 3-node network
  # is racy even after `provider_done`, so poll a few times before giving up.
  LookupAttempts = 10
  LookupDelay = 1.seconds
  RedisWaitTimeout = 60.seconds

type Role = enum
  bootstrap
  provider
  querier

type KadConfig = object
  role: Role
  redisAddr: string
  testKey: string
  bindIp: string

proc readKadConfig(): KadConfig =
  let roleStr = getEnv("ROLE")
  let role =
    case roleStr
    of "bootstrap": Role.bootstrap
    of "provider": Role.provider
    of "querier": Role.querier
    else:
      raise newException(CatchableError, "unknown or missing ROLE: '" & roleStr & "'")
  let testKey = getEnv("TEST_KEY")
  if testKey.len == 0:
    raise newException(CatchableError, "TEST_KEY env var is required")
  KadConfig(
    role: role,
    redisAddr: getEnv("REDIS_ADDR", "transport-redis:6379"),
    testKey: testKey,
    bindIp: resolveBindIp("0.0.0.0"),
  )

proc buildSwitch(config: KadConfig): Switch =
  ## Reuse the shared switch builder with the kad-dht fixed transport stack.
  let base = BaseConfig(
    isDialer: config.role != Role.bootstrap,
    bindIp: config.bindIp,
    redisAddr: config.redisAddr,
    testKey: config.testKey,
    transport: "tcp",
    secureChannel: "noise",
    muxer: "yamux",
    testTimeout: DefaultTestTimeout,
  )
  buildBaseSwitch(base).build()

proc provideKey(testKey: string): Key =
  ## Raw UTF-8 bytes of the logical key, matching go/js/py/dotnet, which
  ## advertise non-multihash provider keys. The receiver accepts these because
  ## provider keys are length-bounded rather than required to be multihashes.
  ("interop-test-key-" & testKey).toBytes()

proc valueKey(testKey: string): Key =
  ("/example/data/" & testKey).toBytes()

proc newKad(switch: Switch): KadDHT =
  KadDHT.new(switch, config = KadDHTConfig.new(quorum = 1), rng = rng())

proc connectBootstrap(
    switch: Switch, kad: KadDHT, redisClient: Redis, testKey: string
) {.async.} =
  ## Fetch the bootstrap multiaddr from Redis, dial it, and seed the routing table.
  let raw = await redisClient.fetchValue(testKey, BootstrapAddrSuffix, RedisWaitTimeout)
  let bootstrapMA = MultiAddress.init(raw).tryGet()
  let bootstrapPeerId = await switch.connect(bootstrapMA)
  kad.updatePeers(@[(bootstrapPeerId, @[bootstrapMA])])
  info "Connected to bootstrap", peerId = bootstrapPeerId

proc runBootstrap(config: KadConfig, switch: Switch, redisClient: Redis) {.async.} =
  let kad = newKad(switch)
  switch.mount(kad)
  await switch.start()
  defer:
    await switch.stop()
  await kad.start()

  let myAddr = switch.peerInfo.fullAddrs.tryGet()[0]
  redisClient.publishValue(config.testKey, BootstrapAddrSuffix, $myAddr)
  info "Bootstrap published multiaddr", address = $myAddr

  await sleepAsync(1.hours) # harness aborts the stack once the querier exits

proc runProvider(config: KadConfig, switch: Switch, redisClient: Redis) {.async.} =
  let kad = newKad(switch)
  switch.mount(kad)
  await switch.start()
  defer:
    await switch.stop()

  await connectBootstrap(switch, kad, redisClient, config.testKey)
  await kad.start()

  await kad.addProvider(provideKey(config.testKey))
  info "Provider announced key"

  let putRes = await kad.putValue(valueKey(config.testKey), ProviderValue.toBytes())
  if putRes.isErr:
    raise newException(CatchableError, "putValue failed: " & putRes.error)
  info "Provider stored value"

  redisClient.publishValue(config.testKey, ProviderDoneSuffix, "done")
  await sleepAsync(1.hours)

proc fail(msg: string) =
  echo "error: " & msg
  echo "status: fail"
  flushFile(stdout)
  quit(QuitFailure)

proc runQuerier(config: KadConfig, switch: Switch, redisClient: Redis) {.async.} =
  let kad = newKad(switch)
  switch.mount(kad)
  await switch.start()
  defer:
    await switch.stop()

  # Wait until the provider is done before connecting (matches py/dotnet).
  discard await redisClient.fetchValue(config.testKey, ProviderDoneSuffix, RedisWaitTimeout)
  await connectBootstrap(switch, kad, redisClient, config.testKey)
  await kad.start()

  # Test 2: find the provider record.
  let pkey = provideKey(config.testKey)
  var providerCount = 0
  for attempt in 0 ..< LookupAttempts:
    try:
      providerCount = (await kad.getProviders(pkey)).len
    except LPStreamError as e:
      debug "getProviders attempt failed", attempt = attempt, err = e.msg
    if providerCount > 0:
      break
    await sleepAsync(LookupDelay)
  if providerCount == 0:
    fail("no providers found for key after " & $LookupAttempts & " attempts")
  info "Querier found providers", count = providerCount

  # Test 4: read the stored value.
  let vkey = valueKey(config.testKey)
  var value = ""
  for attempt in 0 ..< LookupAttempts:
    let getRes = await kad.getValue(vkey)
    if getRes.isOk:
      value = string.fromBytes(getRes.get().value)
      break
    else:
      debug "getValue attempt failed", attempt = attempt, err = getRes.error
    await sleepAsync(LookupDelay)
  if "hello from" notin value:
    fail("unexpected or missing value: '" & value & "'")
  info "Querier retrieved value", value = value

  echo "status: pass"
  flushFile(stdout)

proc main() {.async.} =
  let config = readKadConfig()
  info "Kad-dht interop peer", role = config.role, testKey = config.testKey
  let switch = buildSwitch(config)
  let redisClient = setupRedis(config.redisAddr)
  case config.role
  of Role.bootstrap:
    await runBootstrap(config, switch, redisClient)
  of Role.provider:
    await runProvider(config, switch, redisClient)
  of Role.querier:
    await runQuerier(config, switch, redisClient)

let testTimeout = parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout)
runMain(main, testTimeout)

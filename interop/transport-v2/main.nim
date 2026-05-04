# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, redis
import ../../libp2p/[builders, protocols/ping]
import ../unified_testing

logScope:
  topics = "transport interop"

# The transport interop plans (rust/go/js/python implementations) exchange the
# listener multiaddr via RPUSH/LPOP on the namespaced list key.
proc publishListenerAddr(client: Redis, testKey: string, sw: Switch) =
  let addrs = sw.peerInfo.fullAddrs.tryGet()
  if addrs.len == 0:
    raise newException(CatchableError, "Listener has no addresses")
  discard client.rPush(makeKey(testKey, ListenerMultiaddrSuffix), $addrs[0])

proc fetchListenerAddr(
    client: Redis, testKey: string, timeout: Duration
): Future[MultiAddress] {.async.} =
  let key = makeKey(testKey, ListenerMultiaddrSuffix)
  var val: string
  proc hasValue(): bool =
    val = client.lPop(key)
    val != redisNil and val.len > 0

  pollUntil(hasValue(), timeout, 500.milliseconds, "Timeout waiting for Redis list: " & key)
  MultiAddress.init(val).tryGet()

proc runListener(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    switch = buildBaseSwitch(config).build()

  switch.mount(Ping.new(rng = rng()))
  await switch.start()
  defer:
    await switch.stop()

  publishListenerAddr(redisClient, config.testKey, switch)
  info "Published listener multiaddr"

  # Listener stays alive until terminated by the test harness.
  await sleepAsync(100.hours)

proc runDialer(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    pingProtocol = Ping.new(rng = rng())
    switch = buildBaseSwitch(config).build()

  switch.mount(pingProtocol)
  await switch.start()
  defer:
    await switch.stop()

  let
    remoteAddr =
      await fetchListenerAddr(redisClient, config.testKey, config.testTimeout)
    dialingStart = Moment.now()
    remotePeerId = await switch.connect(remoteAddr)
    stream = await switch.dial(remotePeerId, PingCodec)
    pingDelay = await pingProtocol.ping(stream)
    totalDelay = Moment.now() - dialingStart
  await stream.close()

  printLatencyYaml(totalDelay.toMs(), pingDelay.toMs())

proc main() {.async.} =
  let config = readBaseConfig()
  info "Test configuration", config
  if config.isDialer:
    await runDialer(config)
  else:
    await runListener(config)

let testTimeout = parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout)
runMain(main, testTimeout)

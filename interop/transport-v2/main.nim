# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles
import ../../libp2p/[builders, protocols/ping]
import ../unified_testing

logScope:
  topics = "transport interop"

proc runListener(config: BaseConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    switch = buildBaseSwitch(config).build()

  switch.mount(Ping.new(rng = rng()))
  await switch.start()
  defer:
    await switch.stop()

  publishListenerMultiaddr(redisClient, config.testKey, switch)
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
      await fetchListenerMultiaddr(redisClient, config.testKey, config.testTimeout)
    dialingStart = Moment.now()
    remotePeerId = await switch.connect(remoteAddr)
    stream = await switch.dial(remotePeerId, PingCodec)
    pingDelay = await pingProtocol.ping(stream)
    totalDelay = Moment.now() - dialingStart
  await stream.close()

  printLatencyYaml(totalDelay.toMs(), pingDelay.toMs())

proc main() =
  let config = readBaseConfig()
  info "Test configuration", config

  runMain(config.testTimeout):
    if config.isDialer:
      await runDialer(config)
    else:
      await runListener(config)

main()

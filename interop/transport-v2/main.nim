# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, strutils]
import chronos, chronicles
import ../../libp2p/[builders, protocols/ping]
import ../unified_testing

logScope:
  topics = "transport interop"

type Config = object
  isDialer: bool
  bindIp: string
  redisAddr: string
  testKey: string
  transport: string
  secureChannel: string
  muxer: string

proc readConfig(): Config =
  let config = Config(
    isDialer: getEnv("IS_DIALER") == "true",
    bindIp: resolveBindIp(getEnv("LISTENER_IP", "0.0.0.0")),
    redisAddr: getEnv("REDIS_ADDR", "redis:6379"),
    testKey: getEnv("TEST_KEY"),
    transport: getEnv("TRANSPORT"),
    secureChannel: getEnv("SECURE_CHANNEL"),
    muxer: getEnv("MUXER"),
  )
  info "Test configuration", config
  config

let testTimeout =
  try:
    seconds(parseInt(getEnv("TEST_TIMEOUT_SECS")))
  except CatchableError:
    3.minutes

proc main() {.async.} =
  let
    config = readConfig()
    redisClient = setupRedis(config.redisAddr)
    rng = newRng()
    builder = SwitchBuilder.new().withRng(rng)

  builder.addTransport(config.transport, config.bindIp)
  builder.addSecureChannel(config.secureChannel)
  builder.addMuxer(config.muxer)

  let
    switch = builder.build()
    pingProtocol = Ping.new(rng = rng)
  switch.mount(pingProtocol)
  await switch.start()
  defer:
    await switch.stop()

  let multiaddrKey = config.testKey & "_listener_multiaddr"

  if not config.isDialer:
    discard redisClient.rPush(multiaddrKey, $switch.peerInfo.fullAddrs.tryGet()[0])
    await sleepAsync(100.hours) # will get cancelled
  else:
    let listenerAddr =
      try:
        redisClient.bLPop(@[multiaddrKey], testTimeout.seconds.int)[1]
      except Exception as e:
        raise newException(CatchableError, "Exception calling bLPop: " & e.msg, e)
    let
      remoteAddr = MultiAddress.init(listenerAddr).tryGet()
      dialingStart = Moment.now()
      remotePeerId = await switch.connect(remoteAddr)
      stream = await switch.dial(remotePeerId, PingCodec)
      pingDelay = await pingProtocol.ping(stream)
      totalDelay = Moment.now() - dialingStart
    await stream.close()

    printLatencyYaml(totalDelay.toMs(), pingDelay.toMs())

runMain(testTimeout):
  await main()

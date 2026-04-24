# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[os, strutils], chronos
import ../../libp2p/[builders, protocols/ping]
import ../unified_testing

let testTimeout =
  try:
    seconds(parseInt(getEnv("TEST_TIMEOUT_SECS")))
  except CatchableError:
    3.minutes

proc main() {.async.} =
  let
    transport = getEnv("TRANSPORT")
    muxer = getEnv("MUXER")
    secureChannel = getEnv("SECURE_CHANNEL")
    isDialer = getEnv("IS_DIALER") == "true"
    testKey = getEnv("TEST_KEY")
    ip = resolveBindIp(getEnv("LISTENER_IP", "0.0.0.0"))
    redisClient = setupRedis(getEnv("REDIS_ADDR", "redis:6379"))
    rng = newRng()
    switchBuilder = SwitchBuilder.new().withRng(rng)

  switchBuilder.addTransport(transport, ip)
  switchBuilder.addSecureChannel(secureChannel)
  switchBuilder.addMuxer(muxer)

  let
    switch = switchBuilder.build()
    pingProtocol = Ping.new(rng = rng)
  switch.mount(pingProtocol)
  await switch.start()
  defer:
    await switch.stop()

  if not isDialer:
    discard redisClient.rPush(
      testKey & "_listener_multiaddr", $switch.peerInfo.fullAddrs.tryGet()[0]
    )
    await sleepAsync(100.hours) # will get cancelled
  else:
    let listenerAddr =
      try:
        redisClient.bLPop(@[testKey & "_listener_multiaddr"], testTimeout.seconds.int)[
          1
        ]
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

    echo "latency:"
    echo "  handshake_plus_one_rtt: " & $float(totalDelay.milliseconds)
    echo "  ping_rtt: " & $float(pingDelay.milliseconds)
    echo "  unit: ms"

runMain(testTimeout):
  await main()

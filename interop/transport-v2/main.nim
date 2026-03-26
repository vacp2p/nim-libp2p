# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[os, strutils, sequtils], chronos, redis
import ../../libp2p/[builders, protocols/ping, transports/wstransport]

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
    envIp = getEnv("LISTENER_IP", "0.0.0.0")
    ip =
      # nim-libp2p doesn't do snazzy ip expansion
      if envIp == "0.0.0.0":
        block:
          let addresses =
            getInterfaces().filterIt(it.name == "eth0").mapIt(it.addresses)
          if addresses.len < 1 or addresses[0].len < 1:
            quit "Can't find local ip!"
          ($addresses[0][0].host).split(":")[0]
      else:
        envIp
    redisAddr = getEnv("REDIS_ADDR", "redis:6379").split(":")

    # using synchronous redis because async redis is based on
    # asyncdispatch instead of chronos
    redisClient = open(redisAddr[0], Port(parseInt(redisAddr[1])))

    switchBuilder = SwitchBuilder.new()

  case transport
  of "tcp":
    discard switchBuilder.withTcpTransport().withAddress(
        MultiAddress.init("/ip4/" & ip & "/tcp/0").tryGet()
      )
  of "quic-v1":
    discard switchBuilder.withQuicTransport().withAddress(
        MultiAddress.init("/ip4/" & ip & "/udp/0/quic-v1").tryGet()
      )
  of "ws":
    discard switchBuilder.withWsTransport().withAddress(
        MultiAddress.init("/ip4/" & ip & "/tcp/0/ws").tryGet()
      )
  else:
    raiseAssert "unsupported transport"

  case secureChannel
  of "noise":
    discard switchBuilder.withNoise()

  case muxer
  of "yamux":
    discard switchBuilder.withYamux()
  of "mplex":
    discard switchBuilder.withMplex()

  let
    rng = newRng()
    switch = switchBuilder.withRng(rng).build()
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

    # YAML format
    echo "latency:"
    echo "  handshake_plus_one_rtt: " & $float(totalDelay.milliseconds)
    echo "  ping_rtt: " & $float(pingDelay.milliseconds)
    echo "  unit: ms"

try:
  proc mainAsync(): Future[string] {.async.} =
    # mainAsync wraps main and returns some value, as otherwise
    # 'waitFor(fut)' has no type (or is ambiguous)
    await main()
    return "done"

  discard waitFor(mainAsync().wait(testTimeout))
except AsyncTimeoutError as e:
  error "Program execution timed out", description = e.msg
  quit(-1)
except CatchableError as e:
  error "Unexpected error", description = e.msg
  quit(-1)

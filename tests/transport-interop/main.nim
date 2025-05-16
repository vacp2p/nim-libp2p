import std/[os, strutils, sequtils], chronos, redis, serialization, json_serialization
import ../../libp2p/[builders, protocols/ping, transports/wstransport]

type ResultJson = object
  handshakePlusOneRTTMillis: float
  pingRTTMilllis: float

let testTimeout =
  try:
    seconds(parseInt(getEnv("test_timeout_seconds")))
  except CatchableError:
    3.minutes

proc main() {.async.} =
  let
    transport = getEnv("transport")
    muxer = getEnv("muxer")
    secureChannel = getEnv("security")
    isDialer = getEnv("is_dialer") == "true"
    envIp = getEnv("ip", "0.0.0.0")
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
    redisAddr = getEnv("redis_addr", "redis:6379").split(":")

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
    discard switchBuilder
      .withTransport(
        proc(upgr: Upgrade, privateKey: PrivateKey): Transport =
          WsTransport.new(upgr)
      )
      .withAddress(MultiAddress.init("/ip4/" & ip & "/tcp/0/ws").tryGet())
  else:
    doAssert false

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
    discard redisClient.rPush("listenerAddr", $switch.peerInfo.fullAddrs.tryGet()[0])
    await sleepAsync(100.hours) # will get cancelled
  else:
    let listenerAddr =
      try:
        redisClient.bLPop(@["listenerAddr"], testTimeout.seconds.int)[1]
      except Exception as e:
        raise newException(CatchableError, e.msg)
    let
      remoteAddr = MultiAddress.init(listenerAddr).tryGet()
      dialingStart = Moment.now()
      remotePeerId = await switch.connect(remoteAddr)
      stream = await switch.dial(remotePeerId, PingCodec)
      pingDelay = await pingProtocol.ping(stream)
      totalDelay = Moment.now() - dialingStart
    await stream.close()

    echo Json.encode(
      ResultJson(
        handshakePlusOneRTTMillis: float(totalDelay.milliseconds),
        pingRTTMilllis: float(pingDelay.milliseconds),
      )
    )

try:
  discard waitFor(main().wait(testTimeout))
except AsyncTimeoutError:
  error "Program execution timed out."
  quit(-1)
except CatchableError as e:
  error "Unexpected error", description = e.msg
  quit(-1)

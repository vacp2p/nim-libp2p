import stew/endians2, stew/byteutils, tables, strutils, os, redis, sequtils
import chronos, chronos/apps/http/httpserver
import ./env
import std/hashes
import ./libp2p, ./libp2p/[muxers/mplex/lpchannel, crypto/secp, multiaddress]
import ./libp2p/protocols/[pubsub/pubsubpeer, pubsub/rpc/messages, ping]
import ./libp2p/utils/heartbeat
import math, metrics, metrics/chronos_httpserver
from times import getTime, Time, toUnix, fromUnix, `-`, initTime, `$`, inMilliseconds
from nativesockets import getHostname

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  return ok(($m.data.hash).toBytes())

proc createMessageHandler(): proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
  var messagesChunks: CountTable[uint64]

  return proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let sentUint = uint64.fromBytesLE(data)
    # warm-up
    if sentUint < 1000000:
      return

    messagesChunks.inc(sentUint)
    if messagesChunks[sentUint] < chunks:
      return
    let
      sentMoment = nanoseconds(int64(uint64.fromBytesLE(data)))
      sentNanosecs = nanoseconds(sentMoment - seconds(sentMoment.seconds))
      sentDate = initTime(sentMoment.seconds, sentNanosecs)
      diff = getTime() - sentDate
    echo sentUint, " milliseconds: ", diff.inMilliseconds()

proc messageValidator(topic: string, msg: Message): Future[ValidationResult] {.async.} =
  return ValidationResult.Accept

proc publishNewMessage(
    gossipSub: GossipSub, msgSize: int, topic: string
): Future[(Time, int)] {.async.} =
  let
    now = getTime()
    nowInt = seconds(now.toUnix()) + nanoseconds(times.nanosecond(now))
  var
    res = 0
    #create payload with timestamp, so the receiver can discover elapsed time
    nowBytes =
      @(toBytesLE(uint64(nowInt.nanoseconds))) & newSeq[byte](msgSize div chunks)

  #To support message fragmentation, we add fragment #. Each fragment (chunk) differs by one byte
  for chunk in 0 ..< chunks:
    nowBytes[10] = byte(chunk)
    res = await gossipSub.publish(topic, nowBytes)
  return (now, res)

proc initializeGossipsub(switch: Switch, anonymize: bool): GossipSub =
  return GossipSub.init(
    switch = switch,
    triggerSelf = parseBool(getEnv("SELFTRIGGER", "true")),
    msgIdProvider = msgIdProvider,
    verifySignature = false,
    anonymize = anonymize,
  )

proc configureGossipsubParams(gossipSub: GossipSub) =
  gossipSub.parameters.floodPublish = true
  gossipSub.parameters.opportunisticGraftThreshold = -10000
  gossipSub.parameters.heartbeatInterval = 1.seconds
  gossipSub.parameters.pruneBackoff = 60.seconds
  gossipSub.parameters.gossipFactor = 0.25
  gossipSub.parameters.d = 6
  gossipSub.parameters.dLow = 4
  gossipSub.parameters.dHigh = 8
  gossipSub.parameters.dScore = 6
  gossipSub.parameters.dOut = 6 div 2
  gossipSub.parameters.dLazy = 6

proc connectGossipsubPeers(
    switch: Switch, addrs: seq[string], connectTo: int, rng: ref HmacDrbgContext
): Future[Result[int, string]] {.async.} =
  var multiAddrs = addrs

  rng.shuffle(multiAddrs)

  #Make target connections
  var connected = 0
  for peer in multiAddrs.mapIt(MultiAddress.init(it).tryGet()):
    if connected > connectTo:
      break
    try:
      discard await switch.connect(peer, allowUnknownPeerId = true).wait(5.seconds)
      connected.inc()
      info "Connected!: current connections ",
        connected = $connected, target = connectTo
    except CatchableError as exc:
      warn "Failed to dial ", theirAddress = peer, message = exc.msg
      await sleepAsync(15.seconds)

  if connected == 0:
    return err("Failed to connect any peer")
  elif connected < connectTo:
    warn "Connected to fewer peers than target",
      connected = connected, target = connectTo
  return ok(connected)

proc subscribGossipsubTopic(gossipSub: GossipSub, topic: string) =
  gossipSub.topicParams[topic] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9,
  )

  gossipSub.subscribe(topic, createMessageHandler())
  gossipSub.addValidator([topic], messageValidator)

proc meshHeartbeat(hostname: string, gossipSub: GossipSub) {.async.} =
  heartbeat "mesh details", 5.seconds:
    info "Mesh details ",
      hostname,
      meshPeers = gossipSub.mesh.getOrDefault("test").len,
      gossipPeers = gossipSub.gossipsub.getOrDefault("test").len

proc main() {.async.} =
  let
    rng = libp2p.newRng()
    (hostname, connectTo, address) = getPeerDetails().valueOr:
      error "Error reading peer settings ", err = error
      return

  var builder = SwitchBuilder
    .new()
    .withNoise()
    .withAddress(MultiAddress.init(address).tryGet())
    .withMaxConnections(parseInt(getEnv("MAXCONNECTIONS", "250")))
    .withRng(rng)

  if getEnv("TRANSPORT", "QUIC") == "QUIC":
    builder = builder.withQuicTransport()
  else:
    builder = builder.withTcpTransport().withYamux()

  let
    switch = builder.build()
    gossipSub = initializeGossipsub(switch, true)

  configureGossipsubParams(gossipSub)
  subscribGossipsubTopic(gossipSub, "test")
  switch.mount(gossipSub)
  await switch.start()

  # Metrics
  info "Starting metrics server", hostname
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), prometheusPort)
  if metricsServer.isErr:
    error "Failed to initialize metrics server", hostname, err = metricsServer.error

  info "Listening on ", hostname, address = switch.peerInfo.addrs[^1]
  info "Peer details ", hostname, peerId = switch.peerInfo.peerId

  # Wait for redis

  let redisAddr = getEnv("redis_addr", "redis:6379").split(":")

  let redisClient = open(redisAddr[0], Port(parseInt(redisAddr[1])))

  discard redisClient.sadd("node", $switch.peerInfo.addrs[^1])

  var members: RedisList
  while true:
    try:
      members = redisClient.smembers("node")
    except:
      error "Could not obtain list of members", hostname, err = getCurrentExceptionMsg()
      quit(1)

    let target = parseInt(getEnv("NUM_LIBP2P_NODES", "10"))
    if members.len == target:
      info "Got all members", hostname, members
      break
    else:
      error "not enough members", hostname, len = members.len, target, members
    await sleepAsync(1.seconds)

  #Wait for node building
  info "Sleeping for 5s to make sure nim-libp2p has started"
  await sleepAsync(5.seconds)

  #connect with peers
  discard (await connectGossipsubPeers(switch, members, connectTo, rng)).valueOr:
    error "Failed to establish any connections", hostname, error = error
    return

  info "Sleeping 5s for mesh to form"
  await sleepAsync(5.seconds)

  asyncSpawn meshHeartbeat(hostname, gossipSub)

  info "Starting listening endpoint for publish controller"

  await sleepAsync(2.days)

waitFor(main())

import stew/endians2, stew/byteutils
import tables, strutils, os
import sequtils, hashes
import metrics, metrics/chronos_httpserver
import chronos
import ../libp2p
import ../libp2p/protocols/pubsub/rpc/messages
import ../libp2p/muxers/mplex/lpchannel
import ../libp2p/protocols/ping
from nativesockets import getHostname

proc msgIdProvider(m: Message): Result[MessageId, ValidationResult] =
  ok(($m.data.hash).toBytes())

proc startMetricsServer(
    serverIp: IpAddress, serverPort: Port
): Result[MetricsHttpServerRef, string] =
  info "Starting metrics HTTP server", serverIp = $serverIp, serverPort = $serverPort
  let metricsServerRes = MetricsHttpServerRef.new($serverIp, serverPort)
  if metricsServerRes.isErr():
    return err("metrics HTTP server start failed: " & $metricsServerRes.error)
  let server = metricsServerRes.value
  try:
    waitFor server.start()
  except CatchableError:
    return err("metrics HTTP server start failed: " & getCurrentExceptionMsg())
  info "Metrics HTTP server started", serverIp = $serverIp, serverPort = $serverPort
  ok(metricsServerRes.value)

proc main() {.async.} =
  # --- Configuration ---
  const topic = "test"
  let
    hostname = getHostname()
    myId = parseInt(getEnv("PEER_NUMBER"))
    publisherCount = parseInt(getEnv("PEERS"))
    connectTo = parseInt(getEnv("CONNECT_TO"))
    msgCount = parseInt(getEnv("MSG_COUNT"))
    msgInterval = parseInt(getEnv("MSG_INTERVAL"))
    msgSize = parseInt(getEnv("MSG_SIZE"))
    isPublisher = myId <= publisherCount
    rng = libp2p.newRng()

  echo "Hostname: ", hostname

  # --- Node Setup ---
  let
    myPort = 5000 + myId
    myAddress = "0.0.0.0:" & $myPort
    address = initTAddress(myAddress)
    switch = SwitchBuilder
      .new()
      .withAddress(MultiAddress.init(address).tryGet())
      .withRng(rng)
      .withYamux()
      .withMaxConnections(250)
      .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
      .withNoise()
      .build()

  let
    gossipSub = GossipSub.init(
      switch = switch,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
    )
    pingProtocol = Ping.new(rng = rng)

  # --- Metrics ---
  echo "Starting metrics HTTP server"
  let metricsServer = startMetricsServer(parseIpAddress("0.0.0.0"), Port(8008))

  # --- GossipSub Parameters ---
  gossipSub.parameters.floodPublish = true
  gossipSub.parameters.opportunisticGraftThreshold = -10000
  gossipSub.parameters.heartbeatInterval = 1.seconds
  gossipSub.parameters.pruneBackoff = 60.seconds
  gossipSub.parameters.gossipFactor = 0.25
  gossipSub.parameters.d = 6
  gossipSub.parameters.dLow = 4
  gossipSub.parameters.dHigh = 8
  gossipSub.parameters.dScore = 6
  gossipSub.parameters.dOut = 3
  gossipSub.parameters.dLazy = 6
  gossipSub.topicParams[topic] = TopicParams(
    topicWeight: 1,
    firstMessageDeliveriesWeight: 1,
    firstMessageDeliveriesCap: 30,
    firstMessageDeliveriesDecay: 0.9,
  )

  # --- Message Handling ---
  const warmupMessages = 5
  var sentMessages: Table[uint64, int64]         # messageId -> send time (nanoseconds)
  var receivedMessages: Table[uint64, seq[int64]] # messageId -> seq of receive times (nanoseconds)
  var latencies: seq[int64]                      # ms latency per message
  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    # Skip warm-up messages by checking their data
    if data == "warmup".toBytes():
      return # warm-up phase
    let msgId = uint64.fromBytesLE(data)
    let sentNs = int64(msgId)
    let nowNs = epochNanoSeconds(Moment.now())
    let latencyDur = nanoseconds(nowNs - sentNs)
    let latencyMicro = microseconds(latencyDur)
    let latencyMs = float(latencyMicro) / 1000.0
    if not receivedMessages.hasKey(msgId):
      receivedMessages[msgId] = @[]
    receivedMessages[msgId].add(nowNs)
    latencies.add(latencyMicro)
    echo "Message ", msgId, " delivered. Latency: ", formatFloat(latencyMs, ffDecimal, 3), " ms"

  proc messageValidator(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async.} =
    ValidationResult.Accept

  gossipSub.subscribe(topic, messageHandler)
  gossipSub.addValidator([topic], messageValidator)
  switch.mount(gossipSub)
  switch.mount(pingProtocol)
  await switch.start()

  echo "Listening on ", switch.peerInfo.addrs
  echo myId, ", ", isPublisher, ", ", switch.peerInfo.peerId
  echo "Waiting 5 seconds for node building..."
  await sleepAsync(5.seconds)

  # --- Peer Discovery & Connection ---

  var
    connected = 0
    addrs: seq[MultiAddress]
  for i in 0 ..< publisherCount:
    if i == myId:
      continue # skip self
    let podAddr = "pod-" & $i & ":" & $(5000 + i)
    try:
      let resolved = resolveTAddress(podAddr).mapIt(MultiAddress.init(it).tryGet())
      addrs.add(resolved)
      echo podAddr, " resolved: ", resolved
    except CatchableError as exc:
      echo "Failed to resolve address:", podAddr, " ", exc.msg
  rng.shuffle(addrs)

  var index = 0
  while connected < connectTo:
    while true:
      try:
        echo "Trying to connect to ", addrs[index]
        let peerId =
          await switch.connect(addrs[index], allowUnknownPeerId = true).wait(5.seconds)
        connected.inc()
        index.inc()
        echo "Connected!"
        break
      except CatchableError as exc:
        echo "Failed to dial", exc.msg
        echo "Waiting 15 seconds..."
        await sleepAsync(15.seconds)

  echo "Waiting 5 seconds for connecting..."
  await sleepAsync(5.seconds)

  echo "Mesh size: ", gossipSub.mesh.getOrDefault(topic).len

  # --- Message Publishing ---
  let turnToPublish = parseInt(getHostname()[4 ..^ 1])
  echo "Publishing turn is: ", turnToPublish

  # Warm-up phase
  echo "[Warm-up] Sending messages"
  for msg in 0 ..< warmupMessages:
    await sleepAsync(msgInterval)
    discard await gossipSub.publish(topic, "warmup".toBytes())

  # Measured phase
  for msg in 0 ..< msgCount:
    await sleepAsync(msgInterval)
    if msg mod publisherCount == turnToPublish:
      let nowMoment = Moment.now()
      let nowNs = epochNanoSeconds(nowMoment)
      var nowBytes = @(toBytesLE(uint64(nowNs))) & newSeq[byte](msgSize)
      sentMessages[uint64(nowNs)] = nowNs
      echo "Sending message ", nowNs, " at: ", $nowMoment
      doAssert((await gossipSub.publish(topic, nowBytes)) > 0)

  # Wait for all messages to be delivered
  echo "Waiting 2 seconds for message delivery..."
  await sleepAsync(2.seconds)

  # Performance summary: only for received messages
  let sentByThisNode = toSeq(sentMessages.keys)
  let receivedKeys = toSeq(receivedMessages.keys)
  echo "\n--- Performance Summary (per node) ---"
  echo "Total messages sent by this node (excluding warm-up): ", sentByThisNode.len
  echo "Messages received by this node: ", receivedKeys.len, "/", msgCount
  if latencies.len > 0:
    let minLatencyMs = float(latencies.min) / 1000.0
    let maxLatencyMs = float(latencies.max) / 1000.0
    var sumLatency: int64 = 0
    for l in latencies:
      sumLatency += l
    let avgLatencyMs = float(sumLatency) / float(latencies.len) / 1000.0
    echo "Latency (ms): min=", formatFloat(minLatencyMs, ffDecimal, 3), ", max=", formatFloat(maxLatencyMs, ffDecimal, 3), ", avg=", formatFloat(avgLatencyMs, ffDecimal, 3)
  else:
    echo "No latency data collected."

waitFor(main())

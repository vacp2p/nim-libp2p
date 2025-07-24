import chronos
import hashes
import json
import metrics
import metrics/chronos_httpserver
import os
import sequtils
import stew/byteutils
import stew/endians2
import strutils
import strformat
import tables
import ../libp2p
import ../libp2p/protocols/pubsub/rpc/messages
import ../libp2p/muxers/mplex/lpchannel
import ../libp2p/protocols/ping

const
  topic* = "test"
  warmupData* = "warmup".toBytes()

proc msgIdProvider*(m: Message): Result[MessageId, ValidationResult] =
  ok(($m.data.hash).toBytes())

proc setupNode*(nodeId: int, rng: ref HmacDrbgContext): (Switch, GossipSub, Ping) =
  let
    myPort = 5000 + nodeId
    myAddress = "0.0.0.0:" & $myPort
    address = initTAddress(myAddress)

    switch = SwitchBuilder
      .new()
      .withAddress(MultiAddress.init(address).tryGet())
      .withRng(rng)
      .withYamux()
      .withTcpTransport(flags = {ServerFlags.TcpNoDelay})
      .withNoise()
      .build()

    gossipSub = GossipSub.init(
      switch = switch,
      msgIdProvider = msgIdProvider,
      verifySignature = false,
      anonymize = true,
    )

    pingProtocol = Ping.new(rng = rng)

  return (switch, gossipSub, pingProtocol)

proc setGossipSubParams*(gossipSub: GossipSub) =
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

proc getLatency*(timestamp: int64): float =
  let nowNs = Moment.now().epochNanoSeconds()
  let diff = (nowNs - timestamp).nanoseconds()
  let latencyMs = float(diff.nanoseconds()) / 1000000.0

  return latencyMs

proc formatLatencyMs*(latency: float): string =
  return formatFloat(latency, ffDecimal, 3)

proc defaultMessageValidator*(
    topic: string, msg: Message
): Future[ValidationResult] {.async.} =
  ValidationResult.Accept

proc createMessageHandler*(
    nodeId: int
): (proc(topic: string, data: seq[byte]) {.async.}, ref Table[uint64, float]) =
  var receivedMessages = new Table[uint64, float]

  proc messageHandler(topic: string, data: seq[byte]) {.async.} =
    # Skip warm-up messages
    if data == warmupData:
      return

    let msgId = uint64.fromBytesLE(data)

    let sentNs = int64(msgId)
    let latency = getLatency(sentNs)

    receivedMessages[msgId] = latency
    info "Message delivered", msgId = msgId, latency = formatLatencyMs(latency), nodeId

  return (messageHandler, receivedMessages)

proc resolvePeersAddresses*(
    nodeCount: int, hostnamePrefix: string, nodeId: int
): seq[MultiAddress] =
  var addrs: seq[MultiAddress]

  for i in 0 ..< nodeCount:
    if i == nodeId:
      continue # skip self

    let peerAddr = hostnamePrefix & $i & ":" & $(5000 + i)
    try:
      let resolved = resolveTAddress(peerAddr).mapIt(MultiAddress.init(it).tryGet())
      addrs.add(resolved)

      debug "Peer resolved", nodeId, peerAddr = peerAddr, resolved = resolved
    except CatchableError as exc:
      warn "Failed to resolve address", peerAddr = peerAddr, error = exc.msg

  return addrs

proc connectPeers*(
    switch: Switch, peersAddresses: seq[MultiAddress], peerLimit: int, nodeId: int
) {.async.} =
  var
    connected = 0
    index = 0
  while connected < peerLimit:
    while true:
      let address = peersAddresses[index]
      try:
        let peerId =
          await switch.connect(address, allowUnknownPeerId = true).wait(5.seconds)
        connected.inc()
        index.inc()
        debug "Connected peer", nodeId, address = address
        break
      except CatchableError as exc:
        warn "Failed to dial, waiting 5s", nodeId, address = address, error = exc.msg
        await sleepAsync(5.seconds)

proc publishMessagesWithWarmup*(
    gossipSub: GossipSub,
    warmupCount: int,
    msgCount: int,
    msgInterval: int,
    msgSize: int,
    publisherCount: int,
    nodeId: int,
): Future[seq[uint64]] {.async.} =
  # Warm-up phase
  info "Sending warmup messages", nodeId
  for msg in 0 ..< warmupCount:
    await sleepAsync(msgInterval)
    discard await gossipSub.publish(topic, warmupData)

  # Measured phase
  var sentMessages: seq[uint64]
  for msg in 0 ..< msgCount:
    await sleepAsync(msgInterval)
    if msg mod publisherCount == nodeId:
      let timestamp = Moment.now().epochNanoSeconds()
      var data = @(toBytesLE(uint64(timestamp))) & newSeq[byte](msgSize)

      info "Sending message", msgId = timestamp, nodeId = nodeId
      doAssert((await gossipSub.publish(topic, data)) > 0)
      sentMessages.add(uint64(timestamp))

  return sentMessages

type LatencyStats* = object
  minLatencyMs*: float
  maxLatencyMs*: float
  avgLatencyMs*: float

proc getLatencyStats*(latencies: seq[float]): LatencyStats =
  var
    minLatencyMs = 0.0
    maxLatencyMs = 0.0
    avgLatencyMs = 0.0

  if latencies.len > 0:
    minLatencyMs = latencies.min
    maxLatencyMs = latencies.max
    let sumLatency = foldl(latencies, a + b, 0.0)
    avgLatencyMs = sumLatency / float(latencies.len)

  return LatencyStats(
    minLatencyMs: minLatencyMs, maxLatencyMs: maxLatencyMs, avgLatencyMs: avgLatencyMs
  )

type Stats* = object
  scenarioName*: string
  totalSent*: int
  totalReceived*: int
  latency*: LatencyStats

proc getStats*(
    scenarioName: string,
    receivedMessages: Table[uint64, float],
    sentMessages: seq[uint64],
): Stats =
  let latencyStats = getLatencyStats(receivedMessages.values().toSeq())

  let stats = Stats(
    scenarioName: scenarioName,
    totalSent: sentMessages.len,
    totalReceived: receivedMessages.len,
    latency: latencyStats,
  )

  return stats

proc `$`*(stats: Stats): string =
  return
    fmt"Scenario:`{stats.scenarioName}`, Messages: sent={stats.totalSent}, received={stats.totalReceived}, " &
    fmt"Latency (ms): min={formatLatencyMs(stats.latency.minLatencyMs)}, " &
    fmt"max={formatLatencyMs(stats.latency.maxLatencyMs)}, " &
    fmt"avg={formatLatencyMs(stats.latency.avgLatencyMs)}"

proc writeResultsToJson*(outputPath: string, scenario: string, stats: Stats) =
  let json =
    %*{
      "results": [
        {
          "scenarioName": scenario,
          "totalSent": stats.totalSent,
          "totalReceived": stats.totalReceived,
          "minLatencyMs": formatLatencyMs(stats.latency.minLatencyMs),
          "maxLatencyMs": formatLatencyMs(stats.latency.maxLatencyMs),
          "avgLatencyMs": formatLatencyMs(stats.latency.avgLatencyMs),
        }
      ]
    }
  writeFile(outputPath, json.pretty)

proc initAggregateStats*(scenarioName: string): Stats =
  return Stats(
    scenarioName: scenarioName,
    totalSent: 0,
    totalReceived: 0,
    latency: LatencyStats(minLatencyMs: Inf, maxLatencyMs: 0, avgLatencyMs: 0),
  )

proc processJsonResults*(
    outputDir: string
): (Table[string, Stats], Table[string, int]) =
  var results: Table[string, Stats]
  var validNodes: Table[string, int]
  const unknownFloat = -1.0

  for kind, path in walkDir(outputDir):
    if kind == pcFile and path.endsWith(".json"):
      let content = readFile(path)
      let json = parseJson(content)
      let scenarios = json["results"].getElems(@[])

      for scenario in scenarios:
        let scenarioName = scenario["scenarioName"].getStr("")

        discard results.hasKeyOrPut(scenarioName, initAggregateStats(scenarioName))
        discard validNodes.hasKeyOrPut(scenarioName, 0)

        let sent = scenario["totalSent"].getInt(0)
        let received = scenario["totalReceived"].getInt(0)
        let minL = scenario["minLatencyMs"].getStr($unknownFloat).parseFloat()
        let maxL = scenario["maxLatencyMs"].getStr($unknownFloat).parseFloat()
        let avgL = scenario["avgLatencyMs"].getStr($unknownFloat).parseFloat()

        results[scenarioName].totalSent += sent
        results[scenarioName].totalReceived += received
        if minL != unknownFloat and maxL != unknownFloat and avgL != unknownFloat:
          if minL < results[scenarioName].latency.minLatencyMs:
            results[scenarioName].latency.minLatencyMs = minL
          if maxL > results[scenarioName].latency.maxLatencyMs:
            results[scenarioName].latency.maxLatencyMs = maxL
          results[scenarioName].latency.avgLatencyMs += avgL # used to store SUM
          validNodes[scenarioName] += 1

  return (results, validNodes)

proc getMarkdownReport*(
    results: Table[string, Stats], validNodes: Table[string, int]
): string =
  let commitSha = getEnv("PR_HEAD_SHA", getEnv("GITHUB_SHA", "unknown"))
  var output: seq[string]
  output.add "<!-- perf-summary-marker -->\n"
  output.add "# 🏁 **Performance Summary**\n"
  output.add fmt"**Commit:** `{commitSha}`  "

  output.add "| Scenario | Nodes | Total messages sent | Total messages received | Latency min (ms) | Latency max (ms) | Latency avg (ms) |"
  output.add "|:---:|:---:|:---:|:---:|:---:|:---:|:---:|"

  for scenarioName, stats in results.pairs:
    let nodes = validNodes[scenarioName]
    let stats = results[scenarioName]
    let globalAvgLatency = stats.latency.avgLatencyMs / float(nodes)
    output.add fmt"| {stats.scenarioName} | {nodes} | {stats.totalSent} | {stats.totalReceived} | {stats.latency.minLatencyMs:.3f} | {stats.latency.maxLatencyMs:.3f} | {globalAvgLatency:.3f} |"

  let markdown = output.join("\n")

  return markdown

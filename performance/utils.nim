import chronos
import hashes
import json
import metrics
import metrics/chronos_httpserver
import os
import osproc
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
import ../tests/helpers
import ./types

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
    debug "Message delivered", msgId = msgId, latency = formatLatencyMs(latency), nodeId

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
  proc connectPeer(address: MultiAddress): Future[bool] {.async.} =
    try:
      let peerId =
        await switch.connect(address, allowUnknownPeerId = true).wait(1.seconds)
      debug "Connected peer", nodeId, address, peerId
      return true
    except CatchableError as exc:
      warn "Failed to dial, waiting 1s", nodeId, address = address, error = exc.msg
      return false

  for index in 0 ..< peerLimit:
    checkUntilTimeoutCustom(5.seconds, 500.milliseconds):
      await connectPeer(peersAddresses[index])

proc publishMessagesWithWarmup*(
    gossipSub: GossipSub,
    warmupCount: int,
    msgCount: int,
    msgInterval: int,
    msgSize: int,
    publisherCount: int,
    nodeId: int,
): Future[seq[uint64]] {.async.} =
  info "Publishing messages", nodeId
  # Warm-up phase
  debug "Sending warmup messages", nodeId
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

      debug "Sending message", msgId = timestamp, nodeId = nodeId
      doAssert((await gossipSub.publish(topic, data)) > 0)
      sentMessages.add(uint64(timestamp))

  return sentMessages

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
    fmt"Messages: sent={stats.totalSent}, received={stats.totalReceived}, " &
    fmt"Latency (ms): min={formatLatencyMs(stats.latency.minLatencyMs)}, " &
    fmt"max={formatLatencyMs(stats.latency.maxLatencyMs)}, " &
    fmt"avg={formatLatencyMs(stats.latency.avgLatencyMs)}"

proc writeResultsToJson*(outputPath: string, scenario: string, stats: Stats) =
  var resultsArr: JsonNode = newJArray()
  if fileExists(outputPath):
    try:
      let existing = parseFile(outputPath)
      resultsArr = existing["results"]
    except:
      discard

  let newResult =
    %*{
      "scenarioName": scenario,
      "totalSent": stats.totalSent,
      "totalReceived": stats.totalReceived,
      "minLatencyMs": formatLatencyMs(stats.latency.minLatencyMs),
      "maxLatencyMs": formatLatencyMs(stats.latency.maxLatencyMs),
      "avgLatencyMs": formatLatencyMs(stats.latency.avgLatencyMs),
    }
  resultsArr.add(newResult)

  let json = %*{"results": resultsArr}
  writeFile(outputPath, json.pretty)

const
  enableTcCommand* = "tc qdisc add dev eth0 root"
  disableTcCommand* = "tc qdisc del dev eth0 root"

proc execShellCommand*(cmd: string): string =
  try:
    let output = execProcess(
        "/bin/sh", args = ["-c", cmd], options = {poUsePath, poStdErrToStdOut}
      )
      .strip()
    debug "Shell command executed", cmd, output
    return output
  except OSError as e:
    raise newException(OSError, "Shell command failed")

const syncDir = "/output/sync"

proc syncNodes*(stage: string, nodeId, nodeCount: int) {.async.} =
  # initial wait
  await sleepAsync(2.seconds)

  let prefix = "sync_"
  let myFile = syncDir / (prefix & stage & "_" & $nodeId)
  writeFile(myFile, "ok")

  let expectedFiles = (0 ..< nodeCount).mapIt(syncDir / (prefix & stage & "_" & $it))
  checkUntilTimeoutCustom(5.seconds, 100.milliseconds):
    expectedFiles.allIt(fileExists(it))

  # final wait
  await sleepAsync(500.milliseconds)

proc clearSyncFiles*() =
  if not dirExists(syncDir):
    createDir(syncDir)
  else:
    for f in walkDir(syncDir):
      if fileExists(f.path):
        removeFile(f.path)

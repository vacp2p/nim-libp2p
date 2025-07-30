import metrics
import metrics/chronos_httpserver
import os
import strformat
import strutils
import ../libp2p
import ../libp2p/protocols/ping
import ./utils
from nativesockets import getHostname

proc baseTest*(scenarioName = "Base test") {.async.} =
  # --- Scenario ---
  let scenario = scenarioName
  const
    nodeCount = 10
    publisherCount = 5
    peerLimit = 5
    msgCount = 100
    msgInterval = 100 # ms
    msgSize = 200 # bytes
    warmupCount = 10

  # --- Node Setup ---
  let
    hostnamePrefix = getEnv("HOSTNAME_PREFIX", "unknown")
    nodeId = parseInt(getEnv("NODE_ID", "0"))
    hostname = getHostname()
    rng = libp2p.newRng()

  if nodeId == 0:
    clearSyncFiles()

  let (switch, gossipSub, pingProtocol) = setupNode(nodeId, rng)
  gossipSub.setGossipSubParams()

  var (messageHandler, receivedMessages) = createMessageHandler(nodeId)
  gossipSub.subscribe(topic, messageHandler)

  gossipSub.addValidator([topic], defaultMessageValidator)

  switch.mount(gossipSub)
  switch.mount(pingProtocol)

  await switch.start()
  defer:
    await switch.stop()

  info "Node started, synchronizing",
    scenario,
    nodeId,
    address = switch.peerInfo.addrs,
    peerId = switch.peerInfo.peerId,
    isPublisher = nodeId <= publisherCount,
    hostname = hostname

  await syncNodes("started", nodeId, nodeCount)

  # --- Peer Discovery & Connection ---
  var peersAddresses = resolvePeersAddresses(nodeCount, hostnamePrefix, nodeId)
  rng.shuffle(peersAddresses)

  await connectPeers(switch, peersAddresses, peerLimit, nodeId)

  info "Mesh populated, synchronizing",
    nodeId, meshSize = gossipSub.mesh.getOrDefault(topic).len

  await syncNodes("mesh", nodeId, nodeCount)

  # --- Message Publishing ---
  let sentMessages = await publishMessagesWithWarmup(
    gossipSub, warmupCount, msgCount, msgInterval, msgSize, publisherCount, nodeId
  )

  info "Waiting for message delivery, synchronizing"

  await syncNodes("published", nodeId, nodeCount)

  # --- Performance summary  ---
  let stats = getStats(scenario, receivedMessages[], sentMessages)
  info "Performance summary", nodeId, stats = $stats

  let outputPath = "/output/" & hostname & ".json"
  writeResultsToJson(outputPath, scenario, stats)

  await syncNodes("finished", nodeId, nodeCount)

proc latencyTest*() {.async.} =
  const
    latency = 100
    jitter = 20

  discard execShellCommand(
    fmt"{enableTcCommand} netem delay {latency}ms {jitter}ms distribution normal"
  )
  await baseTest(fmt"Latency {latency}ms {jitter}ms")
  discard execShellCommand(disableTcCommand)

proc packetLossTest*() {.async.} =
  const packetLoss = 5

  discard execShellCommand(fmt"{enableTcCommand} netem loss {packetLoss}%")
  await baseTest(fmt"Packet Loss {packetLoss}%")
  discard execShellCommand(disableTcCommand)

proc lowBandwithTest*() {.async.} =
  const
    rate = "256kbit"
    burst = "8kbit"
    limit = "5000"

  discard
    execShellCommand(fmt"{enableTcCommand} tbf rate {rate} burst {burst} limit {limit}")
  await baseTest(fmt"Low Bandwidth rate {rate} burst {burst} limit {limit}")
  discard execShellCommand(disableTcCommand)

proc packetReorderTest*() {.async.} =
  const
    reorderPercent = 15
    reorderCorr = 40
    delay = 2

  discard execShellCommand(
    fmt"{enableTcCommand} netem delay {delay}ms reorder {reorderPercent}% {reorderCorr}%"
  )
  await baseTest(
    fmt"Packet Reorder {reorderPercent}% {reorderCorr}% with {delay}ms delay"
  )
  discard execShellCommand(disableTcCommand)

proc burstLossTest*() {.async.} =
  const
    lossPercent = 8
    lossCorr = 30

  discard execShellCommand(fmt"{enableTcCommand} netem loss {lossPercent}% {lossCorr}%")
  await baseTest(fmt"Burst Loss {lossPercent}% {lossCorr}%")
  discard execShellCommand(disableTcCommand)

proc duplicationTest*() {.async.} =
  const duplicatePercent = 2

  discard execShellCommand(fmt"{enableTcCommand} netem duplicate {duplicatePercent}%")
  await baseTest(fmt"Duplication {duplicatePercent}%")
  discard execShellCommand(disableTcCommand)

proc corruptionTest*() {.async.} =
  const corruptPercent = 0.5

  discard execShellCommand(fmt"{enableTcCommand} netem corrupt {corruptPercent}%")
  await baseTest(fmt"Corruption {corruptPercent}%")
  discard execShellCommand(disableTcCommand)

proc queueLimitTest*() {.async.} =
  const queueLimit = 5

  discard execShellCommand(fmt"{enableTcCommand} netem limit {queueLimit}")
  await baseTest(fmt"Queue Limit {queueLimit}")
  discard execShellCommand(disableTcCommand)

proc combinedTest*() {.async.} =
  discard execShellCommand(
    "tc qdisc add dev eth0 root handle 1:0 tbf rate 2mbit burst 32kbit limit 25000"
  )
  discard execShellCommand(
    "tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 100ms 20ms distribution normal loss 5% 20% reorder 10% 30% duplicate 0.5% corrupt 0.05% limit 20"
  )
  await baseTest("Combined Network Conditions")
  discard execShellCommand(disableTcCommand)

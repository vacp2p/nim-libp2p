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

  info "Node started, waiting 5s",
    nodeId,
    address = switch.peerInfo.addrs,
    peerId = switch.peerInfo.peerId,
    isPublisher = nodeId <= publisherCount,
    hostname = hostname
  await sleepAsync(5.seconds)

  # --- Peer Discovery & Connection ---
  var peersAddresses = resolvePeersAddresses(nodeCount, hostnamePrefix, nodeId)
  rng.shuffle(peersAddresses)

  await connectPeers(switch, peersAddresses, peerLimit, nodeId)

  info "Mesh populated, waiting 5s",
    nodeId, meshSize = gossipSub.mesh.getOrDefault(topic).len
  await sleepAsync(5.seconds)

  # --- Message Publishing ---
  let sentMessages = await publishMessagesWithWarmup(
    gossipSub, warmupCount, msgCount, msgInterval, msgSize, publisherCount, nodeId
  )

  info "Waiting 5 seconds for message delivery"
  await sleepAsync(5.seconds)

  # --- Performance summary  ---
  let stats = getStats(scenario, receivedMessages[], sentMessages)
  info "Performance summary", nodeId, stats = $stats

  let outputPath = "/output/" & hostname & ".json"
  writeResultsToJson(outputPath, scenario, stats)

proc latencyTest*() {.async.} =
  const
    latency = 100
    jitter = 20

  let enable = execShellCommand(
    fmt"{enableTcCommand} netem delay {latency}ms {jitter}ms distribution normal"
  )
  echo "TC Enable ", enable

  await baseTest(fmt"Latency {latency}ms {jitter}ms")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc packetLossTest*() {.async.} =
  const packetLoss = 5

  let enable = execShellCommand(fmt"{enableTcCommand} netem loss {packetLoss}%")
  echo "TC Enable ", enable

  await baseTest(fmt"Packet Loss {packetLoss}%")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc lowBandwithTest*() {.async.} =
  const
    rate = "128kbit"
    burst = "4kbit"
    limit = "1000"

  let enable =
    execShellCommand(fmt"{enableTcCommand} tbf rate {rate} burst {burst} limit {limit}")
  echo "TC Enable ", enable

  await baseTest(fmt"Low Bandwidth rate {rate} burst {burst} limit {limit}")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc packetReorderTest*() {.async.} =
  const
    reorderPercent = 15
    reorderCorr = 40
    delay = 2

  # tc netem requires a delay to enable reordering
  let enable = execShellCommand(
    fmt"{enableTcCommand} netem delay {delay}ms reorder {reorderPercent}% {reorderCorr}%"
  )
  echo "TC Enable ", enable

  await baseTest(
    fmt"Packet Reorder {reorderPercent}% {reorderCorr}% with {delay}ms delay"
  )

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc burstLossTest*() {.async.} =
  const
    lossPercent = 8
    lossCorr = 30

  let enable =
    execShellCommand(fmt"{enableTcCommand} netem loss {lossPercent}% {lossCorr}%")
  echo "TC Enable ", enable

  await baseTest(fmt"Burst Loss {lossPercent}% {lossCorr}%")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc duplicationTest*() {.async.} =
  const duplicatePercent = 2

  let enable =
    execShellCommand(fmt"{enableTcCommand} netem duplicate {duplicatePercent}%")
  echo "TC Enable ", enable

  await baseTest(fmt"Duplication {duplicatePercent}%")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc corruptionTest*() {.async.} =
  const corruptPercent = 0.5

  let enable = execShellCommand(fmt"{enableTcCommand} netem corrupt {corruptPercent}%")
  echo "TC Enable ", enable

  await baseTest(fmt"Corruption {corruptPercent}%")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc queueLimitTest*() {.async.} =
  const queueLimit = 5

  let enable = execShellCommand(fmt"{enableTcCommand} netem limit {queueLimit}")
  echo "TC Enable ", enable

  await baseTest(fmt"Queue Limit {queueLimit}")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

proc combinedAdverseTest*() {.async.} =
  # Add tbf as root (handle 1:0), then netem as child (parent 1:1)
  let enableTbf = execShellCommand(
    "tc qdisc add dev eth0 root handle 1:0 tbf rate 2mbit burst 32kbit limit 25000"
  )
  echo "TC TBF Enable ", enableTbf

  let enableNetem = execShellCommand(
    "tc qdisc add dev eth0 parent 1:1 handle 10: netem delay 100ms 20ms distribution normal loss 5% 20% reorder 10% 30% duplicate 0.5% corrupt 0.05% limit 20"
  )
  echo "TC Netem Enable ", enableNetem

  await baseTest("Combined Adverse Network Conditions")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable ", disable

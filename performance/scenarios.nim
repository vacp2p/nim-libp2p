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
    publisherCount = 10
    peerLimit = 5
    msgCount = 200
    msgInterval = 20 # ms
    msgSize = 500 # bytes
    warmupCount = 20

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
    latency = 300
    jitter = 50

  let enable = execShellCommand(
    fmt"{enableTcCommand} netem delay {latency}ms {jitter}ms distribution normal"
  )
  echo "TC Enable: ", enable

  await baseTest(fmt"Latency {latency}ms {jitter}ms test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc packetLossTest*() {.async.} =
  const packetLoss = 2

  let enable = execShellCommand(fmt"{enableTcCommand} netem loss {packetLoss}%")
  echo "TC Enable: ", enable

  await baseTest(fmt"Packet Loss {packetLoss}% test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc lowBandwithTest*() {.async.} =
  const
    rate = "1mbit"
    burst = "32kbit"
    limit = "12500"

  let enable =
    execShellCommand(fmt"{enableTcCommand} tbf rate {rate} burst {burst} limit {limit}")
  echo "TC Enable: ", enable

  await baseTest(fmt"Low Bandwith rate {rate} burst {burst} limit {limit} test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc packetReorderTest*() {.async.} =
  const
    reorderPercent = 25
    reorderCorr = 50

  let enable = execShellCommand(
    fmt"{enableTcCommand} netem reorder {reorderPercent}% {reorderCorr}%"
  )
  echo "TC Enable: ", enable

  await baseTest(fmt"Packet Reorder {reorderPercent}% {reorderCorr}% test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc burstLossTest*() {.async.} =
  const
    lossPercent = 10
    lossCorr = 25

  let enable =
    execShellCommand(fmt"{enableTcCommand} netem loss {lossPercent}% {lossCorr}%")
  echo "TC Enable: ", enable

  await baseTest(fmt"Burst Loss {lossPercent}% {lossCorr}% test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc duplicationTest*() {.async.} =
  const duplicatePercent = 1

  let enable =
    execShellCommand(fmt"{enableTcCommand} netem duplicate {duplicatePercent}%")
  echo "TC Enable: ", enable

  await baseTest(fmt"Duplication {duplicatePercent}% test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc corruptionTest*() {.async.} =
  const corruptPercent = 0.1

  let enable = execShellCommand(fmt"{enableTcCommand} netem corrupt {corruptPercent}%")
  echo "TC Enable: ", enable

  await baseTest(fmt"Corruption {corruptPercent}% test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

proc queueLimitTest*() {.async.} =
  const queueLimit = 10

  let enable = execShellCommand(fmt"{enableTcCommand} netem limit {queueLimit}")
  echo "TC Enable: ", enable

  await baseTest(fmt"Queue Limit {queueLimit} test")

  let disable = execShellCommand(disableTcCommand)
  echo "TC Disable: ", disable

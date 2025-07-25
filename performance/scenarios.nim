import metrics
import metrics/chronos_httpserver
import os
import strutils
import ../libp2p
import ../libp2p/protocols/ping
import ./utils
from nativesockets import getHostname

proc test1*() {.async.} =
  const
    # --- Scenario ---
    scenario = "Base test"
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

  info "Waiting 2 seconds for message delivery"
  await sleepAsync(2.seconds)

  # --- Performance summary  ---
  let stats = getStats(receivedMessages[], sentMessages)
  info "Performance summary", nodeId, stats = $stats

  let outputPath = "/output/" & hostname & ".json"
  writeResultsToJson(outputPath, scenario, stats)

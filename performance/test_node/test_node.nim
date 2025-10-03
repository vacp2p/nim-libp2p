# Nim-LibP2P
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import metrics
import metrics/chronos_httpserver
import os
import osproc
import strutils
import strformat
import ../../libp2p
import ../../libp2p/protocols/pubsub/peertable
import ../../libp2p/protocols/ping
import ../../tests/helpers
import ./utils
from nativesockets import getHostname

proc baseTest*(scenarioName: string, transport: TransportType) {.async.} =
  # --- Scenario ---
  let scenario = fmt"{scenarioName} ({transport})"
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

  # --- Collect docker stats for one publishing and one non-publishing node ---
  var dockerStatsProc: Process = nil
  if nodeId == 0 or nodeId == publisherCount + 1:
    let dockerStatsLogPath = getDockerStatsLogPath(scenario, nodeId)
    dockerStatsProc = startDockerStatsProcess(nodeId, dockerStatsLogPath)
  defer:
    dockerStatsProc.stopDockerStatsProcess()

  let (switch, gossipSub, pingProtocol) = setupNode(nodeId, rng, transport)
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
  var peersAddresses =
    resolvePeersAddresses(nodeCount, hostnamePrefix, nodeId, transport)
  rng.shuffle(peersAddresses)

  await connectPeers(switch, peersAddresses, peerLimit, nodeId)

  await sleepAsync(10.seconds)

  info "Mesh populated, synchronizing",
    nodeId,
    meshSize = gossipSub.mesh.getOrDefault(topic).len,
    gossipsub = gossipSub.gossipsub.getOrDefault(topic).len,
    outbound = gossipSub.mesh.outboundPeers(topic)

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

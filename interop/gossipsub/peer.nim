# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## GossipSub interop test binary for the Shadow simulator.
##
## Usage:
##   Shadow:  peer --params <path-to-params.json>
##   Local:   peer --node-id=<N> --params <path-to-params.json>
##
## --node-id=<N> bypasses hostname-based node ID detection (which expects
## Shadow hostnames like "node42") and uses 127.0.0.1 for peer address
## resolution instead of Shadow's simulated DNS.
##
## This binary implements the interop test framework contract:
## - Derives node ID from hostname (e.g., "node42" -> 42)
## - Generates deterministic ED25519 key from node ID
## - Listens on TCP/9000
## - Executes script instructions from params.json
## - Logs structured JSON events to stdout

import chronos, nativesockets, parseopt, streams, strutils
import ../../libp2p/[multiaddress, protocols/pubsub/gossipsub, switch]
import ./src/[runner, instructions, node]

proc main() {.async.} =
  var paramsPath = ""
  var nodeIdOpt = -1

  var p = initOptParser()
  var expectParams = false
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdArgument:
      if expectParams:
        paramsPath = p.key
        expectParams = false
    of cmdLongOption:
      if p.key == "params":
        if p.val.len > 0:
          paramsPath = p.val
        else:
          expectParams = true
      elif p.key == "node-id":
        nodeIdOpt = parseInt(p.val)
    of cmdShortOption:
      discard

  if paramsPath.len == 0:
    quit("Must provide --params <path>", QuitFailure)

  let localMode = nodeIdOpt >= 0
  let nodeId =
    if localMode:
      nodeIdOpt
    else:
      getNodeId()
  let instructions = loadParams(paramsPath)

  # Determine GossipSub params from first initGossipSub instruction
  var params = GossipSubParams.init()
  for instr in instructions:
    if instr.kind == InitGossipSub:
      params = instr.gossipSubParams
      break
    elif instr.kind == IfNodeIDEquals and instr.nodeID == nodeId:
      if instr.inner.kind == InitGossipSub:
        params = instr.inner.gossipSubParams
        break

  let logStream = newFileStream(stdout)
  let listenAddr = MultiAddress.init("/ip4/0.0.0.0/tcp/9000").tryGet()

  let runner = newScriptRunner(
    nodeId = nodeId,
    logStream = logStream,
    listenAddr = listenAddr,
    gossipSubParams = params,
    resolveAddr = proc(id: int): MultiAddress {.gcsafe, raises: [CatchableError].} =
      let ip =
        if localMode:
          "127.0.0.1"
        else:
          getHostByName("node" & $id).addrList[0] # Shadow simulated DNS
      MultiAddress.init("/ip4/" & ip & "/tcp/9000").tryGet(),
    enablePartialMessages = true,
  )

  await runner.node.switch.start()
  defer:
    await runner.node.switch.stop()

  await runner.runScript(instructions)

waitFor main()

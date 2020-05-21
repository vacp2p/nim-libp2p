import random
import chronos
import ../../libp2p/standard_setup
export standard_setup

randomize()

proc generateNodes*(num: Natural, gossip: bool = false): seq[Switch] =
  for i in 0..<num:
    result.add(newStandardSwitch(gossip = gossip))

proc subscribeNodes*(nodes: seq[Switch]) {.async.} =
  var dials: seq[Future[void]]
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        dials.add(dialer.connect(node.peerInfo))
  await allFutures(dials)

proc subscribeRandom*(nodes: seq[Switch]) {.async.} =
  var dials: seq[Future[void]]
  for dialer in nodes:
    var dialed: seq[string]
    while dialed.len < nodes.len - 1:
      let node = sample(nodes)
      if node.peerInfo.id notin dialed:
        if dialer.peerInfo.id != node.peerInfo.id:
          dials.add(dialer.connect(node.peerInfo))
          dialed &= node.peerInfo.id
  await allFutures(dials)

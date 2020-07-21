import random, options
import chronos
import ../../libp2p/standard_setup
import ../../libp2p/protocols/pubsub/gossipsub
export standard_setup

randomize()

proc generateNodes*(num: Natural, gossip: bool = false): seq[Switch] =
  for i in 0..<num:
    var switch = newStandardSwitch(gossip = gossip)
    if gossip:
      var gossipSub = GossipSub(switch.pubSub.get())
      gossipSub.parameters.floodPublish = false
    result.add(switch)

proc subscribeNodes*(nodes: seq[Switch]) {.async.} =
  var dials: seq[Future[void]]
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        dials.add(dialer.connect(node.peerInfo))
  await allFutures(dials)

proc subscribeSparseNodes*(nodes: seq[Switch], degree: int = 2) {.async.} =
  if nodes.len < degree:
    raise (ref CatchableError)(msg: "nodes count needs to be greater or equal to degree!")

  var dials: seq[Future[void]]
  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue

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

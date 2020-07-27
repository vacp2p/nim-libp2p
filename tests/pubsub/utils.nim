import random
import chronos
import ../../libp2p/standard_setup
export standard_setup

randomize()

proc generateNodes*(num: Natural, gossip: bool = false): seq[Switch] =
  for i in 0..<num:
    result.add(newStandardSwitch(gossip = gossip))

proc subscribeNodes*(nodes: seq[Switch]): Future[seq[Future[void]]] {.async.} =
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo)
        result.add(dialer.subscribePeer(node.peerInfo))

proc subscribeSparseNodes*(nodes: seq[Switch], degree: int = 2): Future[seq[Future[void]]] {.async.} =
  if nodes.len < degree:
    raise (ref CatchableError)(msg: "nodes count needs to be greater or equal to degree!")

  for i, dialer in nodes:
    if (i mod degree) != 0:
      continue

    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        await dialer.connect(node.peerInfo)
        result.add(dialer.subscribePeer(node.peerInfo))

proc subscribeRandom*(nodes: seq[Switch]): Future[seq[Future[void]]] {.async.} =
  for dialer in nodes:
    var dialed: seq[string]
    while dialed.len < nodes.len - 1:
      let node = sample(nodes)
      if node.peerInfo.id notin dialed:
        if dialer.peerInfo.id != node.peerInfo.id:
          await dialer.connect(node.peerInfo)
          result.add(dialer.subscribePeer(node.peerInfo))
          dialed.add(node.peerInfo.id)

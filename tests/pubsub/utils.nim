import chronos
import ../../libp2p/[standard_setup,
                     protocols/pubsub/pubsub]
export standard_setup

proc generateNodes*(num: Natural,
                    gossip: bool = false,
                    validationTimeout = ValidationTimeout): seq[Switch] =
  for i in 0..<num:
    result.add(newStandardSwitch(gossip = gossip,
                                 validationTimeout = validationTimeout))

proc subscribeNodes*(nodes: seq[Switch]) {.async.} =
  var dials: seq[Future[void]]
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        dials.add(dialer.subscribeToPeer(node.peerInfo))
  await sleepAsync(100.millis)
  await allFutures(dials)

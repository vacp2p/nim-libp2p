import chronos, nimcrypto, strutils, os
import ../../libp2p/daemon/daemonapi

const
  PubSubTopic = "test-net"

proc main(bn: string) {.async.} =
  echo "= Starting P2P node"
  var bootnodes = bn.split(",")
  var api = await newDaemonApi({DHTFull, PSGossipSub, WaitBootstrap},
                               bootstrapNodes = bootnodes,
                               peersRequired = 1)
  var id = await api.identity()
  echo "= P2P node ", id.peer.pretty(), " started:"
  for item in id.addresses:
    echo item

  proc pubsubLogger(api: DaemonAPI,
                    ticket: PubsubTicket,
                    message: PubSubMessage): Future[bool] {.async.} =
    let msglen = len(message.data)
    echo "= Recieved pubsub message with length ", msglen,
         " bytes from peer ", message.peer.pretty(), ": "
    var strdata = cast[string](message.data)
    echo strdata
    result = true

  var ticket = await api.pubsubSubscribe(PubSubTopic, pubsubLogger)

  # Waiting for gossipsub interval
  while true:
    var peers = await api.pubsubListPeers(PubSubTopic)
    if len(peers) > 0:
      break
    await sleepAsync(1000)

  var data = "HELLO\r\n"
  var msgData = cast[seq[byte]](data)
  await api.pubsubPublish(PubSubTopic, msgData)

when isMainModule:
  if paramCount() != 1:
    echo "Please supply bootnodes!"
  else:
    waitFor(main(paramStr(1)))
    while true:
      poll()

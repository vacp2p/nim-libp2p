import chronos, nimcrypto, strutils
import ../../libp2p/daemon/daemonapi
import ../hexdump

const
  PubSubTopic = "test-net"

proc dumpSubscribedPeers(api: DaemonAPI) {.async.} =
  var peers = await api.pubsubListPeers(PubSubTopic)
  echo "= List of connected and subscribed peers:"
  for item in peers:
    echo item.pretty()

proc dumpAllPeers(api: DaemonAPI) {.async.} =
  var peers = await api.listPeers()
  echo "Current connected peers count = ", len(peers)
  for item in peers:
    echo item.peer.pretty()

proc monitor(api: DaemonAPI) {.async.} =
  while true:
    echo "Dumping all peers"
    await dumpAllPeers(api)
    await sleepAsync(5000)

proc main() {.async.} =
  echo "= Starting P2P bootnode"
  var api = await newDaemonApi({DHTFull, PSGossipSub})
  var id = await api.identity()
  echo "= P2P bootnode ", id.peer.pretty(), " started."
  let mcip4 = multiCodec("ip4")
  let mcip6 = multiCodec("ip6")
  echo "= You can use one of this addresses to bootstrap your nodes:"
  for item in id.addresses:
    if item.protoCode() == mcip4 or item.protoCode() == mcip6:
      echo $item & "/ipfs/" & id.peer.pretty()

  asyncSpawn monitor(api)

  proc pubsubLogger(api: DaemonAPI,
                    ticket: PubsubTicket,
                    message: PubSubMessage): Future[bool] {.async.} =
    let msglen = len(message.data)
    echo "= Recieved pubsub message with length ", msglen,
         " bytes from peer ", message.peer.pretty()
    echo dumpHex(message.data)
    await api.dumpSubscribedPeers()
    result = true

  var ticket = await api.pubsubSubscribe(PubSubTopic, pubsubLogger)

when isMainModule:
  waitFor(main())
  while true:
    poll()

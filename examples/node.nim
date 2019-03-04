import chronos, nimcrypto, strutils, os
import ../libp2p/daemon/daemonapi, ../libp2p/[base58, multiaddress]

proc main(bn: string) {.async.} =
  echo "= Starting P2P node"
  var bootnodes = bn.split(",")
  var api = await newDaemonApi({DHTFull, PSGossipSub, WaitBootstrap},
                               bootstrapNodes = bootnodes,
                               peersRequired = 1)
  var id = await api.identity()
  echo "= P2P node ", Base58.encode(id.peer), " started:"
  for item in id.addresses:
    echo item

  proc pubsubLogger(api: DaemonAPI,
                    ticket: PubsubTicket,
                    message: PubSubMessage): Future[bool] {.async.} =
    let bpeer = Base58.encode(message.peer)
    let msglen = len(message.data)
    echo "= Recieved pubsub message wit length ", msglen,
         " bytes from peer ", bpeer
    result = true

  var ticket = await api.pubsubSubscribe("test-net", pubsubLogger)

  var data = "HELLO\r\n"
  var msgData = cast[seq[byte]](data)
  await api.pubsubPublish("test-net", msgData)

when isMainModule:
  if paramCount() != 1:
    echo "Please supply bootnodes!"
  else:
    waitFor(main(paramStr(1)))
    while true:
      poll()

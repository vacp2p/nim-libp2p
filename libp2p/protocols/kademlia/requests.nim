import ../../peerid
import ../../switch
import ../../peerstore
import ./protobuf
import results
import ../../protobuf/minprotobuf

proc encodeFindNodeReply*(
    closerPeers: seq[PeerId], switch: Switch
): ProtoBuffer {.raises: [].} =
  var msg: Message
  msg.msgType = Opt.some(MessageType.findNode)
  for peer in closerPeers:
    let addrs = switch.peerStore[AddressBook][peer]
    if addrs.len == 0:
      continue

    let p = Peer(
      id: peer.getBytes(),
      addrs: addrs,
      connection:
        # TODO: this should likely be optional as it can reveal the network graph of a node
        if switch.isConnected(peer):
          ConnectionType.connected
        else:
          ConnectionType.notConnected,
    )
    msg.closerPeers.add(p)
  return msg.encode()

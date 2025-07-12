import ../../peerid
import ../../switch
import ../../peerstore
import ./protobuf
import ../../protobuf/minprotobuf
import ./keys

proc encodeFindNodeReply*(
    closerPeers: seq[Key], switch: Switch
): ProtoBuffer {.raises: [].} =
  var msg: Message
  msg.msgType = MessageType.findNode
  for peer in closerPeers:
    let peer =
      try:
        peer.toPeerId()
      except ValueError:
        continue
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

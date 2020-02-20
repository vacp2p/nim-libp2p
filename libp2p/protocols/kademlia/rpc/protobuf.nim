import options
import chronicles
import messages,
       ../../../protobuf/minprotobuf
import ../../../peer
 
# XXX: This manual decoding is kind of meh

proc encodeCloserPeer(closerPeer: Peer, pb: var ProtoBuffer) {.gcsafe.} =
  pb.write(initProtoField(1, closerPeer.id))
  for ma in closerPeer.addrs:
    # TODO: Check seq[byte], should work
    pb.write(initProtoFIeld(2, ma))

proc encodeRpcMsg*(msg: RPCMsg): ProtoBuffer {.gcsafe.} =
  result = initProtoBuffer()
  trace "encoding msg: ", msg = msg, strtype = msg.strtype

  result.write(initProtoField(1, msg.strtype)) 

  result.write(initProtoField(2, msg.key))

  if msg.closerPeers.isSome:
    var closerPeers = initProtoBuffer()
    #if some(msg.closerPeers).len > 0:
    for p in msg.closerPeers.get:
      debug "ppp", p = p
      p.encodeCloserPeer(closerPeers)
    #msg.closerPeer.get.encodeCloserPeers(closerPeers)

    # write closerPeers to protobuf
    closerPeers.finish()
    # XXX: Which field?
    result.write(initProtoField(8, closerPeers))

  if result.buffer.len > 0:
    result.finish()

proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} =
  var pb = initProtoBuffer(msg)
  var msg: RPCMsg

  while true:
    if pb.getString(1, msg.strtype) < 0:
      break
    trace "read message field", strtype = msg.strtype
    if pb.getBytes(2, msg.key) < 0:
      break
    trace "read message field", key = msg.key
    #if pb.getBytes(8, msg.closerPeers) < 0:
    #  break
    #trace "read message field", key = msg.closerPeers
    result = msg

# Lets run some tests here for encode
# Then do decode
#

# Example peer
var pstr = "Qmdxy8GAu1pvi35xBAie9sMpMN4G9p6GK6WCNbSCDCDgyp"
var pid = PeerID.init(pstr)
debug "peer id", id = pid.pretty

# XXX: Made up, not a real ma
var addrs: seq[seq[byte]]
addrs.add(pid.getBytes())
var p = Peer(id: pid.getBytes(), addrs: addrs)

var closerPeers: seq[Peer]
closerPeers.add(p)
# Testing encoding and decoding find node reply
var findNodeReplyMessage = RPCMsg(strtype: "FIND_NODE_REPLY",
                                  key: pid.getBytes(),
                                  closerPeers: some(closerPeers))
debug "findNodeReply", msg = findNodeReplyMessage

var encodedFindNodeReply = encodeRpcMsg(findNodeReplyMessage)
debug "findNodeReply encoded", encoded = encodedFindNodeReply

#var decodedFindNode = decodeRpcMsg(encodedFindNode.buffer)
#debug "findNode decoded", decoded = decodedFindNode

#var decodedId =  PeerID.init(decodedFindNode.key)
#debug "findNode decoded id", id = decodedId.pretty

#echo "assert", pstr == decodedId.pretty

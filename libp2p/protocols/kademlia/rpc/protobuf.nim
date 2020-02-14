import options
import chronicles
import messages,
       ../../../protobuf/minprotobuf
import ../../../peer
 
# XXX: This manual decoding is kind of meh

proc decodeFindNode*(pb: var ProtoBuffer): seq[byte] {.gcsafe.} =
  debug "decodeFindNode NYI"
  # XXX
  result = cast[seq[byte]]("foo")

proc encodeRpcMsg*(msg: RPCMsg): ProtoBuffer {.gcsafe.} =
  result = initProtoBuffer()
  debug "encoding msg: ", msg = msg, strtype = msg.strtype

  result.write(initProtoField(1, msg.strtype)) 

  if msg.key.len > 0:
    result.write(initProtoField(2, msg.key))

  result.finish()

proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} =
  var pb = initProtoBuffer(msg)

  while true:
    var msg: RPCMsg
    if pb.getString(1, msg.strtype) < 0:
      break
    debug "read message field", strtype = msg.strtype

    # XXX: Interesting, specifying this breaks above strtype for PING
    if pb.getBytes(2, msg.key) < 0:
      break
    debug "read message field", key = msg.key

    result = msg

# TODO: Move me to testkademlia

## Testing encoding and decoding ping
#var pingMessage = RPCMsg(strtype: "PING")
#debug "pingMessage", msg = pingMessage
#
#var encodedPing = encodeRpcMsg(pingMessage)
#debug "pingMessage encoded", encoded = encodedPing
#
#var decodedPing = decodeRpcMsg(encodedPing.buffer)
#debug "pingMessage decoded", decoded = decodedPing
#
## Example peer
#var pstr = "Qmdxy8GAu1pvi35xBAie9sMpMN4G9p6GK6WCNbSCDCDgyp"
#var pid = PeerID.init(pstr)
#debug "peer id", id = pid.pretty
#
## Testing encoding and decoding find node
#var findNodeMessage = RPCMsg(strtype: "FIND_NODE", key: pid.getBytes())
#debug "findNode", msg = findNodeMessage
#
#var encodedFindNode = encodeRpcMsg(findNodeMessage)
#debug "findNode encoded", encoded = encodedFindNode
#
#var decodedFindNode = decodeRpcMsg(encodedFindNode.buffer)
#debug "findNode decoded", decoded = decodedFindNode
#
#var decodedId =  PeerID.init(decodedFindNode.key)
#debug "findNode decoded id", id = decodedId.pretty
#
#echo pstr == decodedId.pretty

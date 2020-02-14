import options
import chronicles
import messages,
       ../../../protobuf/minprotobuf
import ../../../peer
 
# XXX: This manual decoding is kind of meh

proc encodeRpcMsg*(msg: RPCMsg): ProtoBuffer {.gcsafe.} =
  result = initProtoBuffer()
  trace "encoding msg: ", msg = msg, strtype = msg.strtype

  result.write(initProtoField(1, msg.strtype)) 

  result.write(initProtoField(2, msg.key))

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
    result = msg





























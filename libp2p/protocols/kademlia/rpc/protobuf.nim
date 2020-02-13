import options
import chronicles
import messages,
       ../../../protobuf/minprotobuf
 
# XXX: This manual decoding is kind of meh

proc decodeFindNode*(pb: var ProtoBuffer): seq[byte] {.gcsafe.} =
  debug "decodeFindNode NYI"
  # XXX
  result = cast[seq[byte]]("foo")

#TODO: HERE ATM, just keep writing this
proc encodeRpcMsg*(msg: RPCMsg): ProtoBuffer {.gcsafe.} =
  result = initProtoBuffer()
  debug "encoding msg: ", msg = msg, strtype = msg.strtype

  result.write(initProtoField(1, msg.strtype)) 

  #if msg.strtype.len > 0:
  #  var strtype = initProtoBuffer()
  #  pb.write(initProtoField(1, strtype))
    #msg.strtype.get.encodeStrType(strtype)

  result.finish()
 # if msg.strtype == "PING":
    # encode as string?
  

# TODO: Here

#  if msg.ping.isSome:
#    var ping = 

  #if msg.findnode.isSome:

proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} =
  var pb = initProtoBuffer(msg)

  while true:
    var msg: RPCMsg
    if pb.getString(1, msg.strtype) < 0:
      break
    debug "read message field", strtype = msg.strtype
    result = msg

# Testing encoding and decoding
var pingMessage = RPCMsg(strtype: "PING")
debug "pingMessage", msg = pingMessage

var encodedPing = encodeRpcMsg(pingMessage)
debug "pingMessage encoded", encoded = encodedPing

var decodedPing = decodeRpcMsg(encodedPing.buffer)
debug "pingMessage decoded", decoded = decodedPing

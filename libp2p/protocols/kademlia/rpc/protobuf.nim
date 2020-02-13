import options
import chronicles
import messages,
       ../../../protobuf/minprotobuf
 
# XXX: This manual decoding is kind of meh

proc decodeFindNode*(pb: var ProtoBuffer): seq[byte] {.gcsafe.} =
  debug "decodeFindNode NYI"
  # XXX
  result = cast[seq[byte]]("foo")

proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} =
  var pb = initProtoBuffer(msg)

  while true:
    var field = pb.enterSubMessage()
    debug "processing submessage", field = field
    case field:
    of 0:
      debug "no submessage found in RPC msg"
      break
    of 1:
      # XXX:
      result.ping = some(true)
      #result.ping = pb.decodePing()
    of 2:
      debug "RPC msg findnode NYI"
      # XXX
      #result.findnode = some(msg)
      result.findnode = some(pb.decodeFindNode())
    else:
      raise newException(CatchableError, "message type not recognized")

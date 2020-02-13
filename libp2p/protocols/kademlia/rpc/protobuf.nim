import options
import chronicles
import messages,
       ../../../protobuf/minprotobuf
 
proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} =
  debug "decodeRpcMsg NYI, assuming ping", msg = msg
  result.ping = some(true)

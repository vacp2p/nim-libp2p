when not(compileOption("threads")):
  {.fatal: "Please, compile this program with the --threads:on option!".}

import tables, strformat, strutils
import chronos                              
import ../libp2p/[switch,                   
                  multistream,              
                  crypto/crypto,            
                  protocols/identify,       
                  connection,               
                  transports/transport,     
                  transports/tcptransport,  
                  multiaddress,             
                  peerinfo,                 
                  peer,                     
                  protocols/protocol,       
                  protocols/secure/secure,  
                  protocols/secure/secio,   
                  muxers/muxer,            
                  muxers/mplex/mplex,       
                  muxers/mplex/types]     

const ChatCodec = "/nim-libp2p/chat/1.0.0"
const DefaultAddr = "/ip4/127.0.0.1/tcp/55505"

const Help = """
  Commands: /[?|hep|connect|disconnect|exit]
  help: Prints this help
  connect: dials a remote peer
  disconnect: ends current session
  exit: closes the chat
"""
  

proc processInput(rfd: AsyncFD) {.async.} =
  var transp = fromPipe(rfd)
  while true:
    let a = await transp.readLine()
    echo "You just entered: " & a

proc readInput(wfd: AsyncFD) {.thread.} =
  ## This procedure performs reading from `stdin` and sends data over
  ## pipe to main thread.
  var transp = fromPipe(wfd)

  while true:
    var line = stdin.readLine()
    discard waitFor transp.write(line & "\r\n")

proc main() {.async.} =
  var (rfd, wfd) = createAsyncPipe()
  if rfd == asyncInvalidPipe or wfd == asyncInvalidPipe:
    raise newException(ValueError, "Could not initialize pipe!")
  
  var thread: Thread[AsyncFD]
  thread.createThread(readInput, wfd)
  
  await processInput(rfd)

when isMainModule:      # isMainModule = true when the module is compiled as the main file
  waitFor(main())
 
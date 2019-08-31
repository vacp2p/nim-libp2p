## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import connection, transport, stream, 
       peerinfo, multiaddress

type
  LPProtoHandler* = proc (conn: Connection, 
                          proto: string): 
                          Future[void] {.gcsafe.}

  LPProtocol* = ref object of RootObj
    peerInfo*: PeerInfo
    codec*: string
    handler*: LPProtoHandler

proc newProtocol*(p: typedesc[LPProtocol],
                  peerInfo: PeerInfo): p =
  new result
  result.peerInfo = peerInfo
  result.init()

method init*(p: LPProtocol) {.base, gcsafe.} = discard

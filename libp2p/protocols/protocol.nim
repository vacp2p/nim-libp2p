## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../connection,
       ../peerinfo, 
       ../multiaddress

type
  LPProtoHandler* = proc (conn: Connection, 
                          proto: string): 
                          Future[void] {.gcsafe, closure.}

  LPProtocol* = ref object of RootObj
    codec*: string
    handler*: LPProtoHandler ## this handler gets invoked by the protocol negotiator

method init*(p: LPProtocol) {.base, gcsafe.} = discard

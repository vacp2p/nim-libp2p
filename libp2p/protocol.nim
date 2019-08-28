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
       peerinfo, multiaddress, multistreamselect

type
  ProtoHandler* = proc (conn: Connection, proto: string): Future[void] {.gcsafe.}
  Protocol* = ref object of RootObj
    peerInfo*: PeerInfo
    codec*: string

proc newProtocol*(p: typedesc[Protocol],
                  peerInfo: PeerInfo): p =
  new result
  result.peerInfo = peerInfo
  result.init()

method init*(p: Protocol) {.base.} = discard

method handle*(p: Protocol, peerInfo: PeerInfo, handler: ProtoHandler)
  {.base, async, error: "not implemented!".} = discard

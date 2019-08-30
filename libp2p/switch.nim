## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables
import chronos
import connection, transport, stream, 
       multistreamselect, protocol,
       peerinfo, multiaddress

type
    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connections*: TableRef[string, Connection]
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      ms*: MultisteamSelect

proc newSwitch*(peerInfo: PeerInfo, transports: seq[Transport]): Switch =
  new result
  result.peerInfo = peerInfo
  result.ms = newMultistream()
  result.transports = transports
  result.protocols = newSeq[LPProtocol]()
  result.connections = newTable[string, Connection]()

proc dial*(s: Switch, peer: PeerInfo, proto: string = ""): Future[Connection] {.async.} = discard

proc mount*(s: Switch, protocol: LPProtocol) = discard

proc start*(s: Switch) {.async.} = 
  # TODO: how bad is it that this is a closure?
  proc handle(conn: Connection): Future[void] {.closure, gcsafe.} = 
    s.ms.handle(conn)

  for t in s.transports: # for each transport
    for a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        await t.listen(a, handle) # listen for incoming connections
        break

proc stop*(s: Switch) {.async.} = 
  for c in s.connections.values:
    await c.close()

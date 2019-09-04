## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils
import chronos
import connection, transport, 
       stream/lpstream, 
       multistream, protocol,
       peerinfo, multiaddress,
       identify, muxers/muxer

type
    UnableToSecureError = object of CatchableError
    UnableToIdentifyError = object of CatchableError

    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connections*: TableRef[string, Connection]
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      muxers*: seq[MuxerProvider]
      ms*: MultisteamSelect
      identity*: Identify

proc newSwitch*(peerInfo: PeerInfo, 
                transports: seq[Transport], 
                identity: Identify, 
                muxers: seq[MuxerProvider]): Switch =
  new result
  result.peerInfo = peerInfo
  result.ms = newMultistream()
  result.transports = transports
  result.connections = newTable[string, Connection]()
  result.identity = identity
  result.muxers = muxers
  
  result.ms.addHandler(IdentifyCodec, identity)

proc secure(s: Switch, conn: Connection) {.async, gcsafe.} = 
  ## secure the incoming connection
  discard

proc identify(s: Switch, conn: Connection, peerInfo: PeerInfo) {.async, gcsafe.} =
  ## identify the connection
  s.peerInfo.protocols = s.ms.list() # update protos before engagin in identify
  await s.identity.identify(conn)

proc mux(s: Switch, conn: Connection): Future[bool] {.async, gcsafe.} =
  ## mux incoming connection
  result = true

proc handleConn(s: Switch, conn: Connection) {.async, gcsafe.} =
  ## perform upgrade flow
  try:
    result = s.ms.handle(conn) # handler incoming connection
    await s.secure(conn)
    if await s.mux(conn):
      await s.identify(conn)
  finally:
    await conn.close()

proc dial*(s: Switch, peer: PeerInfo, proto: string = ""): Future[Connection] {.async.} = 
  for t in s.transports: # for each transport
    for a in peer.addrs: # for each address
      if t.handles(a): # check if it can dial it
        result = await t.dial(a)
        await s.secure(result)
        if not await s.ms.select(result, proto):
          raise newException(CatchableError, 
          "Unable to select protocol: " & proto)

proc mount*[T: LPProtocol](s: Switch, proto: T) = 
  if isNil(proto.handler):
    raise newException(CatchableError, 
    "Protocol has to define a handle method or proc")

  if len(proto.codec) <= 0:
    raise newException(CatchableError, 
    "Protocol has to define a codec string")

  s.ms.addHandler(proto.codec, proto)

proc start*(s: Switch) {.async.} = 
  proc handle(conn: Connection): Future[void] {.async, closure, gcsafe.} =
    await s.handleConn(conn)

  for t in s.transports: # for each transport
    for a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        await t.listen(a, handle) # listen for incoming connections

proc stop*(s: Switch) {.async.} = 
  await allFutures(s.transports.mapIt(it.close()))

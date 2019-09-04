## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, options, strformat
import chronos
import connection, transport, 
       stream/lpstream, 
       multistream, protocol,
       peerinfo, multiaddress,
       identify, muxers/muxer,
       peer

type
    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connections*: TableRef[string, Connection]
      muxed*: TableRef[string, Muxer]
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      muxers*: Table[string, MuxerProvider]
      ms*: MultisteamSelect
      identity*: Identify

proc handleConn(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.}

proc newSwitch*(peerInfo: PeerInfo, 
                transports: seq[Transport], 
                identity: Identify, 
                muxers: Table[string, MuxerProvider]): Switch =
  new result
  result.peerInfo = peerInfo
  result.ms = newMultistream()
  result.transports = transports
  result.connections = newTable[string, Connection]()
  result.muxed = newTable[string, Muxer]()
  result.identity = identity
  result.muxers = muxers
  
  result.ms.addHandler(IdentifyCodec, identity)

proc secure(s: Switch, conn: Connection) {.async, gcsafe.} = 
  ## secure the incoming connection
  discard

proc identify(s: Switch, conn: Connection) {.async, gcsafe.} =
  ## identify the connection
  s.peerInfo.protocols = await s.ms.list(conn) # update protos before engagin in identify
  let info = await s.identity.identify(conn, conn.peerInfo)

  let id  = if conn.peerInfo.isSome: conn.peerInfo.get().peerId.pretty else: ""
  if s.connections.contains(id):
    let connection = s.connections[id]
    var peerInfo = conn.peerInfo.get()
    peerInfo.peerId = PeerID.init(info.pubKey) # we might not have a peerId at all
    peerInfo.addrs = info.addrs
    peerInfo.protocols = info.protos

proc mux(s: Switch, conn: Connection): Future[void] {.async, gcsafe.} =
  ## mux incoming connection
  let muxers = toSeq(s.muxers.keys)
  let muxerName = await s.ms.select(conn, muxers)
  if muxerName.len == 0:
    return

  let muxer = s.muxers[muxerName].newMuxer(conn)
  # install stream handler
  muxer.streamHandler = proc (stream: Connection) {.async, gcsafe.} = 
    try:
      asyncDiscard s.handleConn(stream)
    finally:
      await stream.close()

  # do identify first, so that we have a 
  # PeerInfo in case we didn't before
  let stream = await muxer.newStream()
  await s.identify(stream)

  if conn.peerInfo.isSome:
    s.muxed[conn.peerInfo.get().peerId.pretty] = muxer

proc handleConn(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## perform upgrade flow

  # TODO: figure out proper way of handling this.
  # Perhaps it's ok to discard this Future and handle 
  # errors elsewere?
  asyncDiscard s.ms.handle(conn) # handler incoming connection

  if conn.peerInfo.isSome:
    let id = conn.peerInfo.get().peerId.pretty
    if s.connections.contains(id):
      # if we already have a connection for this peer, 
      # close the incoming connection and return the 
      # existing one
      await conn.close()
      return s.connections[id]
    s.connections[id] = conn

  await s.secure(conn) # secure the connection
  await s.mux(conn) # mux it if possible
  result = conn

proc cleanupConn(s: Switch, conn: Connection) {.async, gcsafe.} =
  let id = if conn.peerInfo.isSome: conn.peerInfo.get().peerId.pretty else: ""
  if conn.peerInfo.isSome:
    if s.muxed.contains(id):
      await s.muxed[id].close
    
    if s.connections.contains(id):
      await s.connections[id].close()

proc dial*(s: Switch, peer: PeerInfo, proto: string = ""): Future[Connection] {.async.} = 
  for t in s.transports: # for each transport
    for a in peer.addrs: # for each address
      if t.handles(a): # check if it can dial it
        var conn = await t.dial(a)
        conn = await s.handleConn(conn)
        if s.muxed.contains(peer.peerId.pretty):
          conn = await s.muxed[peer.peerId.pretty].newStream()
        if (await s.ms.select(conn, proto)).len == 0:
          raise newException(CatchableError, 
          &"Unable to select protocol: {proto}")
        result = conn

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
    try:
      asyncDiscard s.handleConn(conn)
    except:
      await s.cleanupConn(conn)

  for t in s.transports: # for each transport
    for a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        await t.listen(a, handle) # listen for incoming connections

proc stop*(s: Switch) {.async.} = 
  await allFutures(s.transports.mapIt(it.close()))

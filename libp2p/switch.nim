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
import connection, 
       transports/transport, 
       stream/lpstream, 
       multistream, 
       protocols/protocol,
       protocols/secure,
       peerinfo, 
       multiaddress,
       protocols/identify, 
       muxers/muxer,
       peer,
       helpers/debug

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
      streamHandler*: StreamHandler
      secureManager*: Secure

proc secure(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} = 
  ## secure the incoming connection

  # plaintext for now, doesn't do anything
  if not (await s.ms.select(conn, s.secureManager.codec)):
    raise newException(CatchableError, "Unable to negotiate a secure channel!")
  
  result = conn

proc identify(s: Switch, conn: Connection) {.async, gcsafe.} =
  ## identify the connection
  # s.peerInfo.protocols = await s.ms.list(conn) # update protos before engagin in identify
  try:
    if (await s.ms.select(conn, s.identity.codec)):
      let info = await s.identity.identify(conn, conn.peerInfo)

      let id  = if conn.peerInfo.isSome: 
        conn.peerInfo.get().peerId.pretty 
        else: 
          ""
      if id.len > 0 and s.connections.contains(id):
        let connection = s.connections[id]
        var peerInfo = conn.peerInfo.get()
        peerInfo.peerId = PeerID.init(info.pubKey) # we might not have a peerId at all
        peerInfo.addrs = info.addrs
        peerInfo.protocols = info.protos
        debug &"identify: identified remote peer {peerInfo.peerId.pretty}"
  except IdentityInvalidMsgError as exc:
    debug exc.msg
  except IdentityNoMatchError as exc:
    debug exc.msg

proc mux(s: Switch, conn: Connection): Future[void] {.async, gcsafe.} =
  ## mux incoming connection
  let muxers = toSeq(s.muxers.keys)
  let muxerName = await s.ms.select(conn, muxers)
  if muxerName.len == 0 or muxerName == "na":
    return

  let muxer = s.muxers[muxerName].newMuxer(conn)
  # install stream handler
  muxer.streamHandler = s.streamHandler

  # do identify first, so that we have a 
  # PeerInfo in case we didn't before
  let stream = await muxer.newStream()
  let handlerFut = muxer.handle()

  # add muxer handler cleanup proc
  handlerFut.addCallback(
      proc(udata: pointer = nil) {.gcsafe.} = 
        if handlerFut.finished:
          debug &"Muxer handler completed for peer {conn.peerInfo.get().peerId.pretty}"
    )
  await s.identify(stream)
  await stream.close() # close idenity stream
  
  # store it in muxed connections if we have a peer for it
  # TODO: We should make sure that this are cleaned up properly
  # on exit even if there is no peer for it. This shouldn't 
  # happen once secio is in place, but still something to keep
  # in mind
  if conn.peerInfo.isSome:
    s.muxed[conn.peerInfo.get().peerId.pretty] = muxer

proc handleConn(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  result = conn
  ## perform upgrade flow
  if result.peerInfo.isSome:
    let id = result.peerInfo.get().peerId.pretty
    if s.connections.contains(id):
      # if we already have a connection for this peer, 
      # close the incoming connection and return the 
      # existing one
      await result.close()
      return s.connections[id]
    s.connections[id] = result

  result = await s.secure(conn) # secure the connection
  await s.mux(result) # mux it if possible

proc cleanupConn(s: Switch, conn: Connection) {.async, gcsafe.} =
  if conn.peerInfo.isSome:
    let id = conn.peerInfo.get().peerId.pretty
    if s.muxed.contains(id):
      await s.muxed[id].close
    
    if s.connections.contains(id):
      await s.connections[id].close()

proc dial*(s: Switch, 
           peer: PeerInfo, 
           proto: string = ""): 
           Future[Connection] {.async.} = 
  for t in s.transports: # for each transport
    for a in peer.addrs: # for each address
      if t.handles(a): # check if it can dial it
        result = await t.dial(a)
        result.peerInfo = some(peer)
        result = await s.handleConn(result)

        # if there is a muxer for the connection
        # use it instead to create a muxed stream
        if s.muxed.contains(peer.peerId.pretty):
          result = await s.muxed[peer.peerId.pretty].newStream()

        debug &"dial: attempting to select remote proto {proto}"
        if not (await s.ms.select(result, proto)):
          debug &"dial: Unable to select protocol: {proto}"
          raise newException(CatchableError, 
          &"Unable to select protocol: {proto}")

proc mount*[T: LPProtocol](s: Switch, proto: T) {.gcsafe.} = 
  if isNil(proto.handler):
    raise newException(CatchableError, 
    "Protocol has to define a handle method or proc")

  if proto.codec.len == 0:
    raise newException(CatchableError, 
    "Protocol has to define a codec string")

  s.ms.addHandler(proto.codec, proto)

proc start*(s: Switch) {.async.} = 
  proc handle(conn: Connection): Future[void] {.async, closure, gcsafe.} =
    try:
      if (await s.ms.select(conn)):
        await s.ms.handle(conn) # handle incoming connection
    except:
      await s.cleanupConn(conn)

  for t in s.transports: # for each transport
    for a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        await t.listen(a, handle) # listen for incoming connections

proc stop*(s: Switch) {.async.} = 
  await allFutures(s.transports.mapIt(it.close()))

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

  let s = result # can't capture result
  result.streamHandler = proc(stream: Connection) {.async, gcsafe.} = 
    # TODO: figure out proper way of handling this.
    # Perhaps it's ok to discard this Future and handle 
    # errors elsewere?
    await s.ms.handle(stream) # handle incoming connection

  result.mount(identity)
  for key, val in muxers:
    val.streamHandler = result.streamHandler
    result.mount(val)

  result.secureManager = Secure(newPlainText())
  result.mount(result.secureManager)

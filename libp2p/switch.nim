## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, options, strformat
import chronos, chronicles
import connection,
       transports/transport,
       stream/lpstream,
       multistream,
       protocols/protocol,
       protocols/secure/secure, # for plain text
       peerinfo,
       multiaddress,
       protocols/identify,
       protocols/pubsub/pubsub,
       muxers/muxer,
       peer

type
    NoPubSubException = object of CatchableError

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
      secureManagers*: seq[Secure]
      pubSub*: Option[PubSub]

proc newNoPubSubException(): ref Exception {.inline.} = 
  result = newException(NoPubSubException, "no pubsub provided!")

proc secure(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} = 
  ## secure the incoming connection

  # plaintext for now, doesn't do anything
  let managers = s.secureManagers.mapIt(it.codec).deduplicate()
  if managers.len == 0:
    raise newException(CatchableError, "No secure managers registered!")

  if (await s.ms.select(conn, s.secureManagers.mapIt(it.codec))).len == 0:
    raise newException(CatchableError, "Unable to negotiate a secure channel!")

  var n = await s.secureManagers[0].secure(conn)
  result = conn

proc identify(s: Switch, conn: Connection) {.async, gcsafe.} =
  ## identify the connection
  # s.peerInfo.protocols = await s.ms.list(conn) # update protos before engagin in identify
  try:
    if (await s.ms.select(conn, s.identity.codec)):
      let info = await s.identity.identify(conn, conn.peerInfo)

      let id  = if conn.peerInfo.peerId.isSome:
        conn.peerInfo.peerId.get().pretty
        else:
          ""

      if id.len > 0 and s.connections.contains(id):
        let connection = s.connections[id]
        var peerInfo = conn.peerInfo

        if info.pubKey.isSome:
          peerInfo.peerId = some(PeerID.init(info.pubKey.get())) # we might not have a peerId at all
        
        if info.addrs.len > 0:
          peerInfo.addrs = info.addrs
        
        if info.protos.len > 0:
          peerInfo.protocols = info.protos

        debug "identify: identified remote peer ", peer = peerInfo.peerId.get().pretty
  except IdentityInvalidMsgError as exc:
    debug "identify: invalid message", msg = exc.msg
  except IdentityNoMatchError as exc:
    debug "identify: peer's public keys don't match ", msg = exc.msg

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
        debug "mux: Muxer handler completed for peer ", peer = conn.peerInfo.peerId.get().pretty
    )
  await s.identify(stream)
  await stream.close() # close idenity stream
  
  # store it in muxed connections if we have a peer for it
  # TODO: We should make sure that this are cleaned up properly
  # on exit even if there is no peer for it. This shouldn't 
  # happen once secio is in place, but still something to keep
  # in mind
  if conn.peerInfo.peerId.isSome:
    s.muxed[conn.peerInfo.peerId.get().pretty] = muxer

proc handleConn(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  result = conn
  ## perform upgrade flow
  if result.peerInfo.peerId.isSome:
    let id = result.peerInfo.peerId.get().pretty
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
  if conn.peerInfo.peerId.isSome:
    let id = conn.peerInfo.peerId.get().pretty
    if s.muxed.contains(id):
      await s.muxed[id].close
    
    if s.connections.contains(id):
      await s.connections[id].close()

proc getMuxedStream(s: Switch, peerInfo: PeerInfo): Future[Option[Connection]] {.async, gcsafe.} = 
  # if there is a muxer for the connection
  # use it instead to create a muxed stream
  if s.muxed.contains(peerInfo.peerId.get().pretty):
    let muxer = s.muxed[peerInfo.peerId.get().pretty]
    let conn = await muxer.newStream()
    result = some(conn)

proc dial*(s: Switch, 
           peer: PeerInfo, 
           proto: string = ""): 
           Future[Connection] {.async.} = 
  for t in s.transports: # for each transport
    for a in peer.addrs: # for each address
      if t.handles(a): # check if it can dial it
        result = await t.dial(a)
        # make sure to assign the peer to the connection
        result.peerInfo = peer
        result = await s.handleConn(result)

        let stream = await s.getMuxedStream(peer)
        if stream.isSome:
          result = stream.get()

        debug "dial: attempting to select remote ", proto = proto
        if not (await s.ms.select(result, proto)):
          debug "dial: Unable to select protocol: ", proto = proto
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

proc subscribeToPeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  if s.pubSub.isSome:
    let conn = await s.dial(peerInfo, s.pubSub.get().codec)
    await s.pubSub.get().subscribeToPeer(conn)

proc subscribe*(s: Switch, topic: string, handler: TopicHandler): Future[void] {.gcsafe.} = 
  if s.pubSub.isNone:
    raise newNoPubSubException()
  
  result = s.pubSub.get().subscribe(topic, handler)

proc unsubscribe*(s: Switch, topics: seq[string]): Future[void] {.gcsafe.} = 
  if s.pubSub.isNone:
    raise newNoPubSubException()
  
  result = s.pubSub.get().unsubscribe(topics)

proc publish*(s: Switch, topic: string, data: seq[byte]): Future[void] {.gcsafe.} = 
  if s.pubSub.isNone:
    raise newNoPubSubException()

  result = s.pubSub.get().publish(topic, data)

proc newSwitch*(peerInfo: PeerInfo,
                transports: seq[Transport],
                identity: Identify,
                muxers: Table[string, MuxerProvider],
                secureManagers: seq[Secure] = @[],
                pubSub: Option[PubSub] = none(PubSub)): Switch =
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

  for s in secureManagers:
    debug "adding secure manager ", codec = s.codec
    result.secureManagers.add(s)
    result.mount(s)

  if result.secureManagers.len == 0:
    # use plain text if no secure managers are provided
    let manager = Secure(newPlainText())
    result.mount(manager)
    result.secureManagers.add(manager)

  result.secureManagers = result.secureManagers.deduplicate()

  if pubSub.isSome:
    result.pubSub = pubSub
    result.mount(pubSub.get())

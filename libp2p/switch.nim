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
       protocols/secure/secure,
       protocols/secure/plaintext, # for plain text
       peerinfo,
       multiaddress,
       protocols/identify,
       protocols/pubsub/pubsub,
       muxers/muxer,
       peer

logScope:
  topic = "Switch"

type
    NoPubSubException = object of CatchableError

    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connections*: Table[string, Connection]
      muxed*: Table[string, Muxer]
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      muxers*: Table[string, MuxerProvider]
      ms*: MultisteamSelect
      identity*: Identify
      streamHandler*: StreamHandler
      secureManagers*: Table[string, Secure]
      pubSub*: Option[PubSub]

proc newNoPubSubException(): ref Exception {.inline.} = 
  result = newException(NoPubSubException, "no pubsub provided!")

proc secure(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} = 
  ## secure the incoming connection

  # plaintext for now, doesn't do anything
  let managers = toSeq(s.secureManagers.keys)
  if managers.len == 0:
    raise newException(CatchableError, "No secure managers registered!")

  let manager = await s.ms.select(conn, toSeq(s.secureManagers.values).mapIt(it.codec))
  if manager.len == 0:
    raise newException(CatchableError, "Unable to negotiate a secure channel!")

  result = await s.secureManagers[manager].secure(conn)

proc identify*(s: Switch, conn: Connection) {.async, gcsafe.} =
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

        trace "identify: identified remote peer ", peer = peerInfo.peerId.get().pretty
  except IdentityInvalidMsgError as exc:
    error "identify: invalid message", msg = exc.msg
  except IdentityNoMatchError as exc:
    error "identify: peer's public keys don't match ", msg = exc.msg

proc mux(s: Switch, conn: Connection): Future[void] {.async, gcsafe.} =
  trace "muxing connection"
  ## mux incoming connection
  let muxers = toSeq(s.muxers.keys)
  if muxers.len == 0:
    warn "no muxers registered, skipping upgrade flow"
    return

  let muxerName = await s.ms.select(conn, muxers)
  if muxerName.len == 0 or muxerName == "na":
    return

  # create new muxer for connection
  let muxer = s.muxers[muxerName].newMuxer(conn)
  # install stream handler
  muxer.streamHandler = s.streamHandler

  # new stream for identify
  let stream = await muxer.newStream()
  let handlerFut = muxer.handle()

  # add muxer handler cleanup proc
  handlerFut.addCallback(
      proc(udata: pointer = nil) {.gcsafe.} = 
        trace "mux: Muxer handler completed for peer ", 
          peer = conn.peerInfo.peerId.get().pretty
    )

  # do identify first, so that we have a 
  # PeerInfo in case we didn't before
  await s.identify(stream)

  # update main connection with refreshed info
  if stream.peerInfo.peerId.isSome:
    conn.peerInfo = stream.peerInfo
  await stream.close() # close idenity stream
  
  trace "connection's peerInfo", peerInfo = conn.peerInfo.peerId

  # store it in muxed connections if we have a peer for it
  # TODO: We should make sure that this are cleaned up properly
  # on exit even if there is no peer for it. This shouldn't 
  # happen once secio is in place, but still something to keep
  # in mind
  if conn.peerInfo.peerId.isSome:
    trace "adding muxer for peer", peer = conn.peerInfo.peerId.get().pretty
    s.muxed[conn.peerInfo.peerId.get().pretty] = muxer

proc upgradeOutgoing(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  trace "handling connection", conn = conn
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
    trace "connection is muxed, retriving muxer and setting up a stream"
    let muxer = s.muxed[peerInfo.peerId.get().pretty]
    let conn = await muxer.newStream()
    result = some(conn)

proc dial*(s: Switch, 
           peer: PeerInfo, 
           proto: string = ""): 
           Future[Connection] {.async.} = 
  trace "dialing peer", peer = peer.peerId.get().pretty
  for t in s.transports: # for each transport
    for a in peer.addrs: # for each address
      if t.handles(a): # check if it can dial it
        result = await t.dial(a)
        # make sure to assign the peer to the connection
        result.peerInfo = peer
        result = await s.upgradeOutgoing(result)

        let stream = await s.getMuxedStream(peer)
        if stream.isSome:
          trace "connection is muxed, return muxed stream"
          result = stream.get()

        trace "dial: attempting to select remote ", proto = proto
        if not (await s.ms.select(result, proto)):
          error "dial: Unable to select protocol: ", proto = proto
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

proc upgradeIncoming(s: Switch, conn: Connection) {.async, gcsafe.} = 
  trace "upgrading incoming connection"
  let ms = newMultistream()

  # secure incoming connections
  proc securedHandler (conn: Connection, 
                       proto: string) 
                       {.async, gcsafe, closure.} =
    trace "Securing connection"
    let secure = s.secureManagers[proto]
    let sconn = await secure.secure(conn)
    if not isNil(sconn):
      # add the muxer
      for muxer in s.muxers.values:
        ms.addHandler(muxer.codec, muxer)
    
    # handle subsequent requests
    await ms.handle(sconn)

  if (await ms.select(conn)): # just handshake
    # add the secure handlers
    for k in s.secureManagers.keys:
      ms.addHandler(k, securedHandler)

  # handle secured connections
  await ms.handle(conn)

proc start*(s: Switch): Future[seq[Future[void]]] {.async, gcsafe.} = 
  proc handle(conn: Connection): Future[void] {.async, closure, gcsafe.} =
    try:
        await s.upgradeIncoming(conn) # perform upgrade on incoming connection
    except:
      await s.cleanupConn(conn)

  var startFuts: seq[Future[void]]
  for t in s.transports: # for each transport
    for a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        var server = await t.listen(a, handle)
        startFuts.add(server)
  result = startFuts # listen for incoming connections

proc stop*(s: Switch) {.async.} = 
  await allFutures(s.transports.mapIt(it.close()))

proc subscribeToPeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  ## Subscribe to pub sub peer
  if s.pubSub.isSome:
    let conn = await s.dial(peerInfo, s.pubSub.get().codec)
    await s.pubSub.get().subscribeToPeer(conn)

proc subscribe*(s: Switch, topic: string, handler: TopicHandler): Future[void] {.gcsafe.} = 
  ## subscribe to a pubsub topic
  if s.pubSub.isNone:
    raise newNoPubSubException()
  
  result = s.pubSub.get().subscribe(topic, handler)

proc unsubscribe*(s: Switch, topics: seq[TopicPair]): Future[void] {.gcsafe.} = 
  ## unsubscribe from topics
  if s.pubSub.isNone:
    raise newNoPubSubException()
  
  result = s.pubSub.get().unsubscribe(topics)

proc publish*(s: Switch, topic: string, data: seq[byte]): Future[void] {.gcsafe.} = 
  # pubslish to pubsub topic
  if s.pubSub.isNone:
    raise newNoPubSubException()

  result = s.pubSub.get().publish(topic, data)

proc newSwitch*(peerInfo: PeerInfo,
                transports: seq[Transport],
                identity: Identify,
                muxers: Table[string, MuxerProvider],
                secureManagers: Table[string, Secure] = initTable[string, Secure](),
                pubSub: Option[PubSub] = none(PubSub)): Switch =
  new result
  result.peerInfo = peerInfo
  result.ms = newMultistream()
  result.transports = transports
  result.connections = initTable[string, Connection]()
  result.muxed = initTable[string, Muxer]()
  result.identity = identity
  result.muxers = muxers
  result.secureManagers = initTable[string, Secure]()

  let s = result # can't capture result
  result.streamHandler = proc(stream: Connection) {.async, gcsafe.} = 
    debug "handling connection for", peerInfo = stream.peerInfo
    await s.ms.handle(stream) # handle incoming connection

  result.mount(identity)
  for key, val in muxers:
    val.streamHandler = result.streamHandler
    val.muxerHandler = proc(muxer: Muxer) {.async, gcsafe.} =
      trace "got new muxer"
      let stream = await muxer.newStream()
      await s.identify(stream)

  for k in secureManagers.keys:
    trace "adding secure manager ", codec = secureManagers[k].codec
    result.secureManagers[k] = secureManagers[k]

  if result.secureManagers.len == 0:
    # use plain text if no secure managers are provided
    warn "no secure managers, falling back to palin text", codec = PlainTextCodec
    result.secureManagers[PlainTextCodec] = Secure(newPlainText())

  if pubSub.isSome:
    result.pubSub = pubSub
    result.mount(pubSub.get())

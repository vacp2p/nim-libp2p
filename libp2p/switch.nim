## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, options, strformat, sets
import chronos, chronicles
import connection,
       transports/transport,
       multistream,
       protocols/protocol,
       protocols/secure/secure,
       protocols/secure/plaintext, # for plain text
       peerinfo,
       protocols/identify,
       protocols/pubsub/pubsub,
       muxers/muxer,
       errors,
       peer

logScope:
  topic = "Switch"

#TODO: General note - use a finite state machine to manage the different
# steps of connections establishing and upgrading. This makes everything
# more robust and less prone to ordering attacks - i.e. muxing can come if
# and only if the channel has been secured (i.e. if a secure manager has been
# previously provided)

type
    NoPubSubException = object of CatchableError

    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connections*: Table[string, Connection]
      muxed*: Table[string, Muxer]
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      muxers*: Table[string, MuxerProvider]
      ms*: MultistreamSelect
      identity*: Identify
      streamHandler*: StreamHandler
      secureManagers*: Table[string, Secure]
      pubSub*: Option[PubSub]
      dialedPubSubPeers: HashSet[string]

proc newNoPubSubException(): ref Exception {.inline.} =
  result = newException(NoPubSubException, "no pubsub provided!")

proc secure(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## secure the incoming connection

  let managers = toSeq(s.secureManagers.keys)
  if managers.len == 0:
    raise newException(CatchableError, "No secure managers registered!")

  let manager = await s.ms.select(conn, toSeq(s.secureManagers.values).mapIt(it.codec))
  if manager.len == 0:
    raise newException(CatchableError, "Unable to negotiate a secure channel!")

  result = await s.secureManagers[manager].secure(conn, true)

proc identify(s: Switch, conn: Connection): Future[PeerInfo] {.async, gcsafe.} =
  ## identify the connection

  if not isNil(conn.peerInfo):
    result = conn.peerInfo

  try:
    if (await s.ms.select(conn, s.identity.codec)):
      let info = await s.identity.identify(conn, conn.peerInfo)

      if info.pubKey.isNone and isNil(result):
        raise newException(CatchableError,
          "no public key provided and no existing peer identity found")

      if info.pubKey.isSome:
        result = PeerInfo.init(info.pubKey.get())
        trace "identify: identified remote peer", peer = result.id

      if info.addrs.len > 0:
        result.addrs = info.addrs

      if info.protos.len > 0:
        result.protocols = info.protos

  except IdentityInvalidMsgError as exc:
    error "identify: invalid message", msg = exc.msg
  except IdentityNoMatchError as exc:
    error "identify: peer's public keys don't match ", msg = exc.msg

proc mux(s: Switch, conn: Connection): Future[void] {.async, gcsafe.} =
  ## mux incoming connection

  trace "muxing connection"
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
  var stream = await muxer.newStream()
  let handlerFut = muxer.handle()

  # add muxer handler cleanup proc
  handlerFut.addCallback do (udata: pointer = nil):
    trace "muxer handler completed for peer",
      peer = conn.peerInfo.id

  # do identify first, so that we have a
  # PeerInfo in case we didn't before
  conn.peerInfo = await s.identify(stream)

  await stream.close() # close identify stream

  trace "connection's peerInfo", peerInfo = $conn.peerInfo

  # store it in muxed connections if we have a peer for it
  if not isNil(conn.peerInfo):
    trace "adding muxer for peer", peer = conn.peerInfo.id
    s.muxed[conn.peerInfo.id] = muxer

proc cleanupConn(s: Switch, conn: Connection) {.async, gcsafe.} =
  if not isNil(conn.peerInfo):
    let id = conn.peerInfo.id
    trace "cleaning up connection for peer", peerId = id
    if id in s.muxed:
      await s.muxed[id].close()
      s.muxed.del(id)

    if id in s.connections:
      if not s.connections[id].closed:
        await s.connections[id].close()
      s.connections.del(id)

    s.dialedPubSubPeers.excl(id)

    # TODO: Investigate cleanupConn() always called twice for one peer.
    if not(conn.peerInfo.isClosed()):
      conn.peerInfo.close()

proc disconnect*(s: Switch, peer: PeerInfo) {.async, gcsafe.} =
  let conn = s.connections.getOrDefault(peer.id)
  if not isNil(conn):
    await s.cleanupConn(conn)

proc getMuxedStream(s: Switch, peerInfo: PeerInfo): Future[Connection] {.async, gcsafe.} =
  # if there is a muxer for the connection
  # use it instead to create a muxed stream
  if peerInfo.id in s.muxed:
    trace "connection is muxed, setting up a stream"
    let muxer = s.muxed[peerInfo.id]
    let conn = await muxer.newStream()
    result = conn

proc upgradeOutgoing(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  try:
    trace "handling connection", conn = $conn
    result = conn

    # don't mux/secure twise
    if conn.peerInfo.id in s.muxed:
      return

    result = await s.secure(result) # secure the connection
    if isNil(result):
      return

    await s.mux(result) # mux it if possible
    s.connections[conn.peerInfo.id] = result
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "Couldn't upgrade outgoing connection", msg = exc.msg
    return nil

proc upgradeIncoming(s: Switch, conn: Connection) {.async, gcsafe.} =
  trace "upgrading incoming connection", conn = $conn
  let ms = newMultistream()

  # secure incoming connections
  proc securedHandler (conn: Connection,
                       proto: string)
                       {.async, gcsafe, closure.} =
    try:
      trace "Securing connection"
      let secure = s.secureManagers[proto]
      let sconn = await secure.secure(conn, false)
      if sconn.isNil:
        return

      # add the muxer
      for muxer in s.muxers.values:
        ms.addHandler(muxer.codec, muxer)

      # handle subsequent requests
      await ms.handle(sconn)
      await sconn.close()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "ending secured handler", err = exc.msg

  if (await ms.select(conn)): # just handshake
    # add the secure handlers
    for k in s.secureManagers.keys:
      ms.addHandler(k, securedHandler)

  try:
    # handle secured connections
    await ms.handle(conn)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    debug "ending multistream", err = exc.msg

proc subscribeToPeer(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.}

proc internalConnect(s: Switch,
                     peer: PeerInfo): Future[Connection] {.async.} =
  let id = peer.id
  trace "Dialing peer", peer = id
  var conn = s.connections.getOrDefault(id)
  if conn.isNil or conn.closed:
    for t in s.transports: # for each transport
      for a in peer.addrs: # for each address
        if t.handles(a):   # check if it can dial it
          trace "Dialing address", address = $a
          try:
            conn = await t.dial(a)
          except CancelledError as exc:
            raise exc
          except CatchableError as exc:
            trace "couldn't dial peer, transport failed", exc = exc.msg, address = a
            continue
          # make sure to assign the peer to the connection
          conn.peerInfo = peer
          conn = await s.upgradeOutgoing(conn)
          if isNil(conn):
            continue

          conn.closeEvent.wait()
            .addCallback do (udata: pointer):
              asyncCheck s.cleanupConn(conn)
          break
  else:
    trace "Reusing existing connection"

  if not isNil(conn):
    await s.subscribeToPeer(peer)

  result = conn

proc connect*(s: Switch, peer: PeerInfo) {.async.} =
  var conn = await s.internalConnect(peer)
  if isNil(conn):
    raise newException(CatchableError, "Unable to connect to peer")

proc dial*(s: Switch,
           peer: PeerInfo,
           proto: string):
           Future[Connection] {.async.} =
  var conn = await s.internalConnect(peer)
  if isNil(conn):
    raise newException(CatchableError, "Unable to establish outgoing link")

  if conn.closed:
    raise newException(CatchableError, "Connection dead on arrival")

  result = conn
  let stream = await s.getMuxedStream(peer)
  if not isNil(stream):
    trace "Connection is muxed, return muxed stream"
    result = stream
    trace "Attempting to select remote", proto = proto

  if not await s.ms.select(result, proto):
    warn "Unable to select sub-protocol", proto = proto
    raise newException(CatchableError, &"unable to select protocol: {proto}")

proc mount*[T: LPProtocol](s: Switch, proto: T) {.gcsafe.} =
  if isNil(proto.handler):
    raise newException(CatchableError,
    "Protocol has to define a handle method or proc")

  if proto.codec.len == 0:
    raise newException(CatchableError,
    "Protocol has to define a codec string")

  s.ms.addHandler(proto.codec, proto)

proc start*(s: Switch): Future[seq[Future[void]]] {.async, gcsafe.} =
  trace "starting switch"

  proc handle(conn: Connection): Future[void] {.async, closure, gcsafe.} =
    try:
      await s.upgradeIncoming(conn) # perform upgrade on incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "Exception occurred in Switch.start", exc = exc.msg
    finally:
      await conn.close()
      await s.cleanupConn(conn)

  var startFuts: seq[Future[void]]
  for t in s.transports: # for each transport
    for i, a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        var server = await t.listen(a, handle)
        s.peerInfo.addrs[i] = t.ma # update peer's address
        startFuts.add(server)

  if s.pubSub.isSome:
    await s.pubSub.get().start()

  result = startFuts # listen for incoming connections

proc stop*(s: Switch) {.async.} =
  trace "stopping switch"

  # we want to report erros but we do not want to fail
  # or crash here, cos we need to clean possibly MANY items
  # and any following conn/transport won't be cleaned up
  if s.pubSub.isSome:
    await s.pubSub.get().stop()

  checkFutures(
    await allFinished(
    toSeq(s.connections.values).mapIt(s.cleanupConn(it))))

  checkFutures(
    await allFinished(
    s.transports.mapIt(it.close())))

  trace "switch stopped"

proc subscribeToPeer(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  ## Subscribe to pub sub peer
  if s.pubSub.isSome and peerInfo.id notin s.dialedPubSubPeers:
    try:
      s.dialedPubSubPeers.incl(peerInfo.id)
      let conn = await s.dial(peerInfo, s.pubSub.get().codec)
      await s.pubSub.get().subscribeToPeer(conn)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "unable to initiate pubsub", exc = exc.msg
    finally:
      s.dialedPubSubPeers.excl(peerInfo.id)

proc subscribe*(s: Switch, topic: string,
                handler: TopicHandler): Future[void] =
  ## subscribe to a pubsub topic
  if s.pubSub.isNone:
    var retFuture = newFuture[void]("Switch.subscribe")
    retFuture.fail(newNoPubSubException())
    return retFuture

  result = s.pubSub.get().subscribe(topic, handler)

proc unsubscribe*(s: Switch, topics: seq[TopicPair]): Future[void] =
  ## unsubscribe from topics
  if s.pubSub.isNone:
    var retFuture = newFuture[void]("Switch.unsubscribe")
    retFuture.fail(newNoPubSubException())
    return retFuture

  result = s.pubSub.get().unsubscribe(topics)

proc publish*(s: Switch, topic: string, data: seq[byte]): Future[void] =
  # pubslish to pubsub topic
  if s.pubSub.isNone:
    var retFuture = newFuture[void]("Switch.publish")
    retFuture.fail(newNoPubSubException())
    return retFuture

  result = s.pubSub.get().publish(topic, data)

proc addValidator*(s: Switch,
                   topics: varargs[string],
                   hook: ValidatorHandler) =
  # add validator
  if s.pubSub.isNone:
    raise newNoPubSubException()

  s.pubSub.get().addValidator(topics, hook)

proc removeValidator*(s: Switch,
                      topics: varargs[string],
                      hook: ValidatorHandler) =
  # pubslish to pubsub topic
  if s.pubSub.isNone:
    raise newNoPubSubException()

  s.pubSub.get().removeValidator(topics, hook)

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
  result.dialedPubSubPeers = initHashSet[string]()

  let s = result # can't capture result
  result.streamHandler = proc(stream: Connection) {.async, gcsafe.} =
    trace "handling connection for", peerInfo = $stream.peerInfo
    await s.ms.handle(stream) # handle incoming connection

  result.mount(identity)
  for key, val in muxers:
    val.streamHandler = result.streamHandler
    val.muxerHandler = proc(muxer: Muxer) {.async, gcsafe.} =
      trace "got new muxer"
      let stream = await muxer.newStream()
      muxer.connection.peerInfo = await s.identify(stream)
      await stream.close()

  for k in secureManagers.keys:
    trace "adding secure manager ", codec = secureManagers[k].codec
    result.secureManagers[k] = secureManagers[k]

  if result.secureManagers.len == 0:
    # use plain text if no secure managers are provided
    warn "no secure managers, falling back to plain text", codec = PlainTextCodec
    result.secureManagers[PlainTextCodec] = Secure(newPlainText())

  if pubSub.isSome:
    result.pubSub = pubSub
    result.mount(pubSub.get())

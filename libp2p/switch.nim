## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables,
       sequtils,
       options,
       strformat,
       sets,
       algorithm

import chronos,
       chronicles,
       metrics

import stream/connection,
       stream/chronosstream,
       transports/transport,
       multistream,
       multiaddress,
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
  topics = "switch"

#TODO: General note - use a finite state machine to manage the different
# steps of connections establishing and upgrading. This makes everything
# more robust and less prone to ordering attacks - i.e. muxing can come if
# and only if the channel has been secured (i.e. if a secure manager has been
# previously provided)

declareGauge(libp2p_peers, "total connected peers")
declareCounter(libp2p_dialed_peers, "dialed peers")
declareCounter(libp2p_failed_dials, "failed dials")
declareCounter(libp2p_failed_upgrade, "peers failed upgrade")

const MaxConnectionsPerPeer = 5

type
    NoPubSubException* = object of CatchableError
    TooManyConnections* = object of CatchableError

    Direction {.pure.} = enum
      In, Out

    ConnectionHolder = object
      dir: Direction
      conn: Connection

    MuxerHolder = object
      dir: Direction
      muxer: Muxer
      handle: Future[void]

    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connections*: Table[string, seq[ConnectionHolder]]
      muxed*: Table[string, seq[MuxerHolder]]
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      muxers*: Table[string, MuxerProvider]
      ms*: MultistreamSelect
      identity*: Identify
      streamHandler*: StreamHandler
      secureManagers*: seq[Secure]
      pubSub*: Option[PubSub]
      dialedPubSubPeers: HashSet[string]
      dialLock: Table[string, AsyncLock]

proc newNoPubSubException(): ref NoPubSubException {.inline.} =
  result = newException(NoPubSubException, "no pubsub provided!")

proc newTooManyConnections(): ref TooManyConnections {.inline.} =
  result = newException(TooManyConnections, "too many connections for peer")

proc disconnect*(s: Switch, peer: PeerInfo) {.async, gcsafe.}

proc selectConn(s: Switch, peerInfo: PeerInfo): Connection =
  ## select the "best" connection according to some criteria
  ##
  ## Ideally when the connection's stats are available
  ## we'd select the fastest, but for now we simply pick an outgoing
  ## connection first if none is available, we pick the first outgoing
  ##

  if isNil(peerInfo):
    return

  let conns = s.connections
    .getOrDefault(peerInfo.id)
    # it should be OK to sort on each
    # access as there should only be
    # up to MaxConnectionsPerPeer entries
    .sorted(
      proc(a, b: ConnectionHolder): int =
        if a.dir < b.dir: -1
        elif a.dir == b.dir: 0
        else: 1
    , SortOrder.Descending)

  if conns.len > 0:
    return conns[0].conn

proc selectMuxer(s: Switch, conn: Connection): Muxer =
  ## select the muxer for the supplied connection
  ##

  if isNil(conn):
    return

  if not(isNil(conn.peerInfo)) and conn.peerInfo.id in s.muxed:
    if s.muxed[conn.peerInfo.id].len > 0:
      let muxers = s.muxed[conn.peerInfo.id]
        .filterIt( it.muxer.connection == conn )
      if muxers.len > 0:
        return muxers[0].muxer

proc storeConn(s: Switch,
               muxer: Muxer,
               dir: Direction,
               handle: Future[void] = nil) {.async.} =
  ## store the connection and muxer
  ##
  if not(isNil(muxer)):
    let conn = muxer.connection
    if not(isNil(conn)):
      let id = conn.peerInfo.id
      if s.connections.getOrDefault(id).len >= MaxConnectionsPerPeer:
        warn "disconnecting peer, too many connections", peer = $conn.peerInfo,
                                                         conns = s.connections
                                                         .getOrDefault(id).len
        await muxer.close()
        await s.disconnect(conn.peerInfo)
        raise newTooManyConnections()

      s.connections.mgetOrPut(
        id,
        newSeq[ConnectionHolder]())
        .add(ConnectionHolder(conn: conn, dir: dir))

    s.muxed.mgetOrPut(
      muxer.connection.peerInfo.id,
      newSeq[MuxerHolder]())
      .add(MuxerHolder(muxer: muxer, handle: handle, dir: dir))

proc secure(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  if s.secureManagers.len <= 0:
    raise newException(CatchableError, "No secure managers registered!")

  let manager = await s.ms.select(conn, s.secureManagers.mapIt(it.codec))
  if manager.len == 0:
    raise newException(CatchableError, "Unable to negotiate a secure channel!")

  trace "securing connection", codec=manager
  let secureProtocol = s.secureManagers.filterIt(it.codec == manager)
  # ms.select should deal with the correctness of this
  # let's avoid duplicating checks but detect if it fails to do it properly
  doAssert(secureProtocol.len > 0)
  result = await secureProtocol[0].secure(conn, true)

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

      if info.agentVersion.isSome:
        result.agentVersion = info.agentVersion.get()

      if info.protoVersion.isSome:
        result.protoVersion = info.protoVersion.get()

      if info.protos.len > 0:
        result.protocols = info.protos

      trace "identify", info = shortLog(result)
  except IdentityInvalidMsgError as exc:
    error "identify: invalid message", msg = exc.msg
  except IdentityNoMatchError as exc:
    error "identify: peer's public keys don't match ", msg = exc.msg

proc mux(s: Switch, conn: Connection): Future[void] {.async, gcsafe.} =
  ## mux incoming connection

  trace "muxing connection", peer = $conn
  let muxers = toSeq(s.muxers.keys)
  if muxers.len == 0:
    warn "no muxers registered, skipping upgrade flow"
    return

  let muxerName = await s.ms.select(conn, muxers)
  if muxerName.len == 0 or muxerName == "na":
    debug "no muxer available, early exit", peer = $conn
    return

  # create new muxer for connection
  let muxer = s.muxers[muxerName].newMuxer(conn)

  trace "found a muxer", name=muxerName, peer = $conn

  # install stream handler
  muxer.streamHandler = s.streamHandler

  # new stream for identify
  var stream = await muxer.newStream()
  # call muxer handler, this should
  # not end until muxer ends
  let handlerFut = muxer.handle()

  try:
    # do identify first, so that we have a
    # PeerInfo in case we didn't before
    conn.peerInfo = await s.identify(stream)
  finally:
    await stream.close() # close identify stream

  if isNil(conn.peerInfo):
    await muxer.close()
    return

  # store it in muxed connections if we have a peer for it
  trace "adding muxer for peer", peer = conn.peerInfo.id
  await s.storeConn(muxer, Direction.Out, handlerFut)

proc cleanupConn(s: Switch, conn: Connection) {.async, gcsafe.} =
  try:
    if not isNil(conn.peerInfo):
      let id = conn.peerInfo.id
      trace "cleaning up connection for peer", peerId = id
      if id in s.muxed:
        let muxerHolder = s.muxed[id]
          .filterIt(
            it.muxer.connection == conn
          )

        if muxerHolder.len > 0:
          await muxerHolder[0].muxer.close()
          if not(isNil(muxerHolder[0].handle)):
            await muxerHolder[0].handle

        s.muxed[id].keepItIf(
          it.muxer.connection != conn
        )

        if s.muxed[id].len == 0:
          s.muxed.del(id)

      if id in s.connections:
        s.connections[id].keepItIf(
          it.conn != conn
        )

        if s.connections[id].len == 0:
          s.connections.del(id)

        await conn.close()
        s.dialedPubSubPeers.excl(id)

      # TODO: Investigate cleanupConn() always called twice for one peer.
      if not(conn.peerInfo.isClosed()):
        conn.peerInfo.close()

  except CatchableError as exc:
    trace "exception cleaning up connection", exc = exc.msg
  finally:
    libp2p_peers.set(s.connections.len.int64)

proc disconnect*(s: Switch, peer: PeerInfo) {.async, gcsafe.} =
  let connections = s.connections.getOrDefault(peer.id)
  for connHolder in connections:
    if not isNil(connHolder.conn):
      await s.cleanupConn(connHolder.conn)

proc getMuxedStream(s: Switch, peerInfo: PeerInfo): Future[Connection] {.async, gcsafe.} =
  # if there is a muxer for the connection
  # use it instead to create a muxed stream

  let muxer = s.selectMuxer(s.selectConn(peerInfo)) # always get the first muxer here
  if not(isNil(muxer)):
    return await muxer.newStream()

proc upgradeOutgoing(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  trace "handling connection", conn = $conn, oid = conn.oid

  let sconn = await s.secure(conn) # secure the connection
  if isNil(sconn):
    trace "unable to secure connection, stopping upgrade", conn = $conn,
                                                           oid = conn.oid
    await conn.close()
    return

  await s.mux(sconn) # mux it if possible
  if isNil(conn.peerInfo):
    trace "unable to mux connection, stopping upgrade", conn = $conn,
                                                        oid = conn.oid
    await sconn.close()
    return

  libp2p_peers.set(s.connections.len.int64)
  trace "succesfully upgraded outgoing connection", conn = $conn,
                                                    oid = conn.oid,
                                                    uoid = sconn.oid
  result = sconn

proc upgradeIncoming(s: Switch, conn: Connection) {.async, gcsafe.} =
  trace "upgrading incoming connection", conn = $conn, oid = conn.oid
  let ms = newMultistream()

  # secure incoming connections
  proc securedHandler (conn: Connection,
                       proto: string)
                       {.async, gcsafe, closure.} =
    try:
      trace "Securing connection", oid = conn.oid
      let secure = s.secureManagers.filterIt(it.codec == proto)[0]
      let sconn = await secure.secure(conn, false)
      if sconn.isNil:
        return

      # add the muxer
      for muxer in s.muxers.values:
        ms.addHandler(muxer.codec, muxer)

      # handle subsequent requests
      try:
        await ms.handle(sconn)
      finally:
        await sconn.close()

    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "ending secured handler", err = exc.msg

  try:
    try:
      if (await ms.select(conn)): # just handshake
        # add the secure handlers
        for k in s.secureManagers:
          ms.addHandler(k.codec, securedHandler)

        # handle secured connections
      await ms.handle(conn)
    finally:
      await conn.close()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error in multistream", err = exc.msg

proc subscribeToPeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.}

proc internalConnect(s: Switch,
                     peer: PeerInfo): Future[Connection] {.async.} =

  if s.peerInfo.peerId == peer.peerId:
    raise newException(CatchableError, "can't dial self!")

  let id = peer.id
  let lock = s.dialLock.mgetOrPut(id, newAsyncLock())
  var conn: Connection

  try:
    await lock.acquire()
    trace "about to dial peer", peer = id
    conn = s.selectConn(peer)
    if conn.isNil or conn.closed:
      trace "Dialing peer", peer = id
      for t in s.transports: # for each transport
        for a in peer.addrs: # for each address
          if t.handles(a):   # check if it can dial it
            trace "Dialing address", address = $a
            try:
              conn = await t.dial(a)
              libp2p_dialed_peers.inc()
            except CatchableError as exc:
              trace "dialing failed", exc = exc.msg
              libp2p_failed_dials.inc()
              continue

            # make sure to assign the peer to the connection
            conn.peerInfo = peer
            conn = await s.upgradeOutgoing(conn)
            if isNil(conn):
              libp2p_failed_upgrade.inc()
              continue

            conn.closeEvent.wait()
            .addCallback do(udata: pointer):
              asyncCheck s.cleanupConn(conn)
            break
    else:
      trace "Reusing existing connection", oid = conn.oid
  except CatchableError as exc:
    trace "exception connecting to peer", exc = exc.msg
    if not(isNil(conn)):
      await conn.close()

    raise exc # re-raise
  finally:
    if lock.locked():
      lock.release()

  if not isNil(conn):
    doAssert(conn.peerInfo.id in s.connections, "connection not tracked!")
    trace "dial succesfull", oid = conn.oid
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
    trace "Connection is muxed, return muxed stream", oid = conn.oid
    result = stream
    trace "Attempting to select remote", proto = proto, oid = conn.oid

  if not await s.ms.select(result, proto):
    raise newException(CatchableError, "Unable to select sub-protocol " & proto)

proc mount*[T: LPProtocol](s: Switch, proto: T) {.gcsafe.} =
  if isNil(proto.handler):
    raise newException(CatchableError,
    "Protocol has to define a handle method or proc")

  if proto.codec.len == 0:
    raise newException(CatchableError,
    "Protocol has to define a codec string")

  s.ms.addHandler(proto.codec, proto)

proc start*(s: Switch): Future[seq[Future[void]]] {.async, gcsafe.} =
  trace "starting switch for peer", peerInfo = shortLog(s.peerInfo)

  proc handle(conn: Connection): Future[void] {.async, closure, gcsafe.} =
    try:
      try:
        await s.upgradeIncoming(conn) # perform upgrade on incoming connection
      finally:
        await s.cleanupConn(conn)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "Exception occurred in Switch.start", exc = exc.msg

  var startFuts: seq[Future[void]]
  for t in s.transports: # for each transport
    for i, a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        var server = await t.listen(a, handle)
        s.peerInfo.addrs[i] = t.ma # update peer's address
        startFuts.add(server)

  if s.pubSub.isSome:
    await s.pubSub.get().start()

  info "started libp2p node", peer = $s.peerInfo, addrs = s.peerInfo.addrs
  result = startFuts # listen for incoming connections

proc stop*(s: Switch) {.async.} =
  try:
    trace "stopping switch"

    # we want to report errors but we do not want to fail
    # or crash here, cos we need to clean possibly MANY items
    # and any following conn/transport won't be cleaned up
    if s.pubSub.isSome:
      await s.pubSub.get().stop()

    for conns in toSeq(s.connections.values):
      for conn in conns:
        try:
            await s.cleanupConn(conn.conn)
        except CatchableError as exc:
          warn "error cleaning up connections"

    for t in s.transports:
      try:
          await t.close()
      except CatchableError as exc:
        warn "error cleaning up transports"

    trace "switch stopped"
  except CatchableError as exc:
    warn "error stopping switch", exc = exc.msg

proc subscribeToPeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  trace "about to subscribe to pubsub peer", peer = peerInfo.shortLog()
  ## Subscribe to pub sub peer
  if s.pubSub.isSome and (peerInfo.id notin s.dialedPubSubPeers):
    let conn = await s.getMuxedStream(peerInfo)
    if isNil(conn):
      trace "unable to subscribe to peer", peer = peerInfo.shortLog
      return

    s.dialedPubSubPeers.incl(peerInfo.id)
    try:
      if (await s.ms.select(conn, s.pubSub.get().codec)):
        await s.pubSub.get().subscribeToPeer(conn)
      else:
        await conn.close()
    except CatchableError as exc:
      trace "exception in subscribe to peer", peer = peerInfo.shortLog, exc = exc.msg
      await conn.close()
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
                secureManagers: openarray[Secure] = [],
                pubSub: Option[PubSub] = none(PubSub)): Switch =
  new result
  result.peerInfo = peerInfo
  result.ms = newMultistream()
  result.transports = transports
  result.connections = initTable[string, seq[ConnectionHolder]]()
  result.muxed = initTable[string, seq[MuxerHolder]]()
  result.identity = identity
  result.muxers = muxers
  result.secureManagers = @secureManagers
  result.dialedPubSubPeers = initHashSet[string]()

  let s = result # can't capture result
  result.streamHandler = proc(stream: Connection) {.async, gcsafe.} =
    try:
      trace "handling connection for", peerInfo = $stream
      try:
        await s.ms.handle(stream) # handle incoming connection
      finally:
        if not(stream.closed):
          await stream.close()
    except CatchableError as exc:
      trace "exception in stream handler", exc = exc.msg

  result.mount(identity)
  for key, val in muxers:
    val.streamHandler = result.streamHandler
    val.muxerHandler = proc(muxer: Muxer) {.async, gcsafe.} =
      var stream: Connection
      try:
        trace "got new muxer"
        stream = await muxer.newStream()
        # once we got a muxed connection, attempt to
        # identify it
        muxer.connection.peerInfo = await s.identify(stream)

        # store muxer and muxed connection
        await s.storeConn(muxer, Direction.In)
        libp2p_peers.set(s.connections.len.int64)

        muxer.connection.closeEvent.wait()
          .addCallback do(udata: pointer):
            asyncCheck s.cleanupConn(muxer.connection)

        # try establishing a pubsub connection
        await s.subscribeToPeer(muxer.connection.peerInfo)

      except CatchableError as exc:
        libp2p_failed_upgrade.inc()
        trace "exception in muxer handler", exc = exc.msg
      finally:
        if not(isNil(stream)):
          await stream.close()

  if result.secureManagers.len <= 0:
    # use plain text if no secure managers are provided
    warn "no secure managers, falling back to plain text", codec = PlainTextCodec
    result.secureManagers &= Secure(newPlainText())

  if pubSub.isSome:
    result.pubSub = pubSub
    result.mount(pubSub.get())

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
       peerid

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
      dialLock: Table[string, AsyncLock]

proc newNoPubSubException(): ref NoPubSubException {.inline.} =
  result = newException(NoPubSubException, "no pubsub provided!")

proc newTooManyConnections(): ref TooManyConnections {.inline.} =
  result = newException(TooManyConnections, "too many connections for peer")

proc disconnect*(s: Switch, peer: PeerInfo) {.async, gcsafe.}
proc subscribeToPeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.}

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
  if isNil(muxer):
    return

  let conn = muxer.connection
  if isNil(conn):
    return

  let id = conn.peerInfo.id
  if s.connections.getOrDefault(id).len > MaxConnectionsPerPeer:
    warn "disconnecting peer, too many connections", peer = $conn.peerInfo,
                                                      conns = s.connections
                                                      .getOrDefault(id).len
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

  trace "securing connection", codec = manager
  let secureProtocol = s.secureManagers.filterIt(it.codec == manager)
  # ms.select should deal with the correctness of this
  # let's avoid duplicating checks but detect if it fails to do it properly
  doAssert(secureProtocol.len > 0)
  result = await secureProtocol[0].secure(conn, true)

proc identify(s: Switch, conn: Connection) {.async, gcsafe.} =
  ## identify the connection

  if (await s.ms.select(conn, s.identity.codec)):
    let info = await s.identity.identify(conn, conn.peerInfo)

    if info.pubKey.isNone and isNil(conn):
      raise newException(CatchableError,
        "no public key provided and no existing peer identity found")

    if isNil(conn.peerInfo):
      conn.peerInfo = PeerInfo.init(info.pubKey.get())

    if info.addrs.len > 0:
      conn.peerInfo.addrs = info.addrs

    if info.agentVersion.isSome:
      conn.peerInfo.agentVersion = info.agentVersion.get()

    if info.protoVersion.isSome:
      conn.peerInfo.protoVersion = info.protoVersion.get()

    if info.protos.len > 0:
      conn.peerInfo.protocols = info.protos

    trace "identify: identified remote peer", peer = $conn.peerInfo

proc mux(s: Switch, conn: Connection) {.async, gcsafe.} =
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

  trace "found a muxer", name = muxerName, peer = $conn

  # install stream handler
  muxer.streamHandler = s.streamHandler

  # new stream for identify
  var stream = await muxer.newStream()
  var handlerFut: Future[void]

  defer:
    if not(isNil(stream)):
      await stream.close() # close identify stream

  # call muxer handler, this should
  # not end until muxer ends
  handlerFut = muxer.handle()

  # do identify first, so that we have a
  # PeerInfo in case we didn't before
  await s.identify(stream)

  if isNil(conn.peerInfo):
    await muxer.close()
    raise newException(CatchableError,
      "unable to identify peer, aborting upgrade")

  # store it in muxed connections if we have a peer for it
  trace "adding muxer for peer", peer = conn.peerInfo.id
  await s.storeConn(muxer, Direction.Out, handlerFut)

proc cleanupConn(s: Switch, conn: Connection) {.async, gcsafe.} =
    if isNil(conn):
      return

    defer:
      await conn.close()
      libp2p_peers.set(s.connections.len.int64)

    if isNil(conn.peerInfo):
      return

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

      if id in s.muxed:
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

    # TODO: Investigate cleanupConn() always called twice for one peer.
    if not(conn.peerInfo.isClosed()):
      conn.peerInfo.close()

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
  logScope:
    conn = $conn
    oid = $conn.oid

  let sconn = await s.secure(conn) # secure the connection
  if isNil(sconn):
    raise newException(CatchableError,
      "unable to secure connection, stopping upgrade")

  trace "upgrading connection"
  await s.mux(sconn) # mux it if possible
  if isNil(sconn.peerInfo):
    await sconn.close()
    raise newException(CatchableError,
      "unable to mux connection, stopping upgrade")

  libp2p_peers.set(s.connections.len.int64)
  trace "succesfully upgraded outgoing connection", uoid = sconn.oid
  return sconn

proc upgradeIncoming(s: Switch, conn: Connection) {.async, gcsafe.} =
  trace "upgrading incoming connection", conn = $conn, oid = conn.oid
  let ms = newMultistream()

  # secure incoming connections
  proc securedHandler (conn: Connection,
                       proto: string)
                       {.async, gcsafe, closure.} =

    var sconn: Connection
    trace "Securing connection", oid = conn.oid
    let secure = s.secureManagers.filterIt(it.codec == proto)[0]

    try:
      sconn = await secure.secure(conn, false)
      if isNil(sconn):
        return

      defer:
        await sconn.close()

      # add the muxer
      for muxer in s.muxers.values:
        ms.addHandler(muxer.codec, muxer)

      # handle subsequent requests
      await ms.handle(sconn)

    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "ending secured handler", err = exc.msg

  if (await ms.select(conn)): # just handshake
    # add the secure handlers
    for k in s.secureManagers:
      ms.addHandler(k.codec, securedHandler)

    # handle secured connections
  await ms.handle(conn)

proc internalConnect(s: Switch,
                     peer: PeerInfo): Future[Connection] {.async.} =

  if s.peerInfo.peerId == peer.peerId:
    raise newException(CatchableError, "can't dial self!")

  let id = peer.id
  let lock = s.dialLock.mgetOrPut(id, newAsyncLock())
  var conn: Connection

  defer:
    if lock.locked():
      lock.release()

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
          except CancelledError as exc:
            trace "dialing canceled", exc = exc.msg
            raise
          except CatchableError as exc:
            trace "dialing failed", exc = exc.msg
            libp2p_failed_dials.inc()
            continue

          # make sure to assign the peer to the connection
          conn.peerInfo = peer
          try:
            conn = await s.upgradeOutgoing(conn)
          except CatchableError as exc:
            if not(isNil(conn)):
              await conn.close()

            trace "Unable to establish outgoing link", exc = exc.msg
            raise exc

          if isNil(conn):
            libp2p_failed_upgrade.inc()
            continue

          conn.closeEvent.wait()
          .addCallback do(udata: pointer):
            asyncCheck s.cleanupConn(conn)
          break
  else:
    trace "Reusing existing connection", oid = conn.oid

  if isNil(conn):
    raise newException(CatchableError,
      "Unable to establish outgoing link")

  if conn.closed or conn.atEof:
    await conn.close()
    raise newException(CatchableError,
      "Connection dead on arrival")

  doAssert(conn.peerInfo.id in s.connections,
    "connection not tracked!")

  trace "dial succesfull", oid = conn.oid
  await s.subscribeToPeer(peer)
  return conn

proc connect*(s: Switch, peer: PeerInfo) {.async.} =
  var conn = await s.internalConnect(peer)

proc dial*(s: Switch,
           peer: PeerInfo,
           proto: string):
           Future[Connection] {.async.} =
  var conn = await s.internalConnect(peer)
  let stream = await s.getMuxedStream(peer)
  if isNil(stream):
    await conn.close()
    raise newException(CatchableError, "Couldn't get muxed stream")

  trace "Attempting to select remote", proto = proto, oid = conn.oid
  if not await s.ms.select(stream, proto):
    await stream.close()
    raise newException(CatchableError, "Unable to select sub-protocol " & proto)

  return stream

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
      defer:
        await s.cleanupConn(conn)

      await s.upgradeIncoming(conn) # perform upgrade on incoming connection
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
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        warn "error cleaning up connections"

  for t in s.transports:
    try:
        await t.close()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "error cleaning up transports"

  trace "switch stopped"

proc subscribeToPeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  ## Subscribe to pub sub peer
  if s.pubSub.isSome and not(s.pubSub.get().connected(peerInfo)):
    trace "about to subscribe to pubsub peer", peer = peerInfo.shortLog()
    var stream: Connection
    try:
      stream = await s.getMuxedStream(peerInfo)
    except CancelledError as exc:
      if not(isNil(stream)):
        await stream.close()

      raise exc
    except CatchableError as exc:
      trace "exception in subscribe to peer", peer = peerInfo.shortLog,
                                              exc = exc.msg
      if not(isNil(stream)):
        await stream.close()

    if isNil(stream):
      trace "unable to subscribe to peer", peer = peerInfo.shortLog
      return

    if not await s.ms.select(stream, s.pubSub.get().codec):
      if not(isNil(stream)):
        await stream.close()
      return

    await s.pubSub.get().subscribeToPeer(stream)

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

proc muxerHandler(s: Switch, muxer: Muxer) {.async, gcsafe.} =
  var stream = await muxer.newStream()
  defer:
    if not(isNil(stream)):
      await stream.close()

  trace "got new muxer"

  try:
    # once we got a muxed connection, attempt to
    # identify it
    await s.identify(stream)
    if isNil(stream.peerInfo):
      await muxer.close()
      return

    muxer.connection.peerInfo = stream.peerInfo

    # store muxer and muxed connection
    await s.storeConn(muxer, Direction.In)
    libp2p_peers.set(s.connections.len.int64)

    muxer.connection.closeEvent.wait()
      .addCallback do(udata: pointer):
        asyncCheck s.cleanupConn(muxer.connection)

    # try establishing a pubsub connection
    await s.subscribeToPeer(muxer.connection.peerInfo)

  except CancelledError as exc:
    await muxer.close()
    raise exc
  except CatchableError as exc:
    await muxer.close()
    libp2p_failed_upgrade.inc()
    trace "exception in muxer handler", exc = exc.msg

proc newSwitch*(peerInfo: PeerInfo,
                transports: seq[Transport],
                identity: Identify,
                muxers: Table[string, MuxerProvider],
                secureManagers: openarray[Secure] = [],
                pubSub: Option[PubSub] = none(PubSub)): Switch =
  if secureManagers.len == 0:
    raise (ref CatchableError)(msg: "Provide at least one secure manager")

  result = Switch(
    peerInfo: peerInfo,
    ms: newMultistream(),
    transports: transports,
    connections: initTable[string, seq[ConnectionHolder]](),
    muxed: initTable[string, seq[MuxerHolder]](),
    identity: identity,
    muxers: muxers,
    secureManagers: @secureManagers,
  )

  let s = result # can't capture result
  result.streamHandler = proc(stream: Connection) {.async, gcsafe.} =
    try:
      trace "handling connection for", peerInfo = $stream
      defer:
        if not(isNil(stream)):
          await stream.close()
      await s.ms.handle(stream) # handle incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in stream handler", exc = exc.msg

  result.mount(identity)
  for key, val in muxers:
    val.streamHandler = result.streamHandler
    val.muxerHandler = proc(muxer: Muxer): Future[void] =
      s.muxerHandler(muxer)

  if pubSub.isSome:
    result.pubSub = pubSub
    result.mount(pubSub.get())

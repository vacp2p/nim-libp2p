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
       sets,
       oids

import chronos,
       chronicles,
       metrics

import stream/connection,
       transports/transport,
       multistream,
       multiaddress,
       protocols/protocol,
       protocols/secure/secure,
       peerinfo,
       protocols/identify,
       protocols/pubsub/pubsub,
       muxers/muxer,
       connmanager,
       peerid,
       errors

logScope:
  topics = "switch"

#TODO: General note - use a finite state machine to manage the different
# steps of connections establishing and upgrading. This makes everything
# more robust and less prone to ordering attacks - i.e. muxing can come if
# and only if the channel has been secured (i.e. if a secure manager has been
# previously provided)

declareCounter(libp2p_dialed_peers, "dialed peers")
declareCounter(libp2p_failed_dials, "failed dials")
declareCounter(libp2p_failed_upgrade, "peers failed upgrade")

const
  MaxPubsubReconnectAttempts* = 10

type
    NoPubSubException* = object of CatchableError

    Lifecycle* {.pure.} = enum
      Connected,
      Upgraded,
      Disconnected

    Hook* = proc(peer: PeerInfo, cycle: Lifecycle): Future[void] {.gcsafe.}

    Switch* = ref object of RootObj
      peerInfo*: PeerInfo
      connManager: ConnManager
      transports*: seq[Transport]
      protocols*: seq[LPProtocol]
      muxers*: Table[string, MuxerProvider]
      ms*: MultistreamSelect
      identity*: Identify
      streamHandler*: StreamHandler
      secureManagers*: seq[Secure]
      pubSub*: Option[PubSub]
      dialLock: Table[string, AsyncLock]
      hooks: Table[Lifecycle, HashSet[Hook]]
      pubsubMonitors: Table[PeerId, Future[void]]

proc newNoPubSubException(): ref NoPubSubException {.inline.} =
  result = newException(NoPubSubException, "no pubsub provided!")

proc addHook*(s: Switch, hook: Hook, cycle: Lifecycle) =
  s.hooks.mgetOrPut(cycle, initHashSet[Hook]()).incl(hook)

proc removeHook*(s: Switch, hook: Hook, cycle: Lifecycle) =
  s.hooks.mgetOrPut(cycle, initHashSet[Hook]()).excl(hook)

proc triggerHooks(s: Switch, peer: PeerInfo, cycle: Lifecycle) {.async, gcsafe.} =
  try:
    if cycle in s.hooks:
      var hooks: seq[Future[void]]
      for h in s.hooks[cycle]:
        if not(isNil(h)):
          hooks.add(h(peer, cycle))

      checkFutures(await allFinished(hooks))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception in trigger hooks", exc = exc.msg

proc disconnect*(s: Switch, peer: PeerInfo) {.async, gcsafe.}
proc subscribePeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.}

proc cleanupPubSubPeer(s: Switch, conn: Connection) {.async.} =
  try:
    await conn.closeEvent.wait()
    if s.pubSub.isSome:
      let fut = s.pubsubMonitors.getOrDefault(conn.peerInfo.peerId)
      if not(isNil(fut)) and not(fut.finished):
        await fut.cancelAndWait()

      await s.pubSub.get().unsubscribePeer(conn.peerInfo)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception cleaning pubsub peer", exc = exc.msg

proc isConnected*(s: Switch, peer: PeerInfo): bool =
  ## returns true if the peer has one or more
  ## associated connections (sockets)
  ##

  peer.peerId in s.connManager

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
  if s.muxers.len == 0:
    warn "no muxers registered, skipping upgrade flow"
    return

  let muxerName = await s.ms.select(conn, toSeq(s.muxers.keys()))
  if muxerName.len == 0 or muxerName == "na":
    debug "no muxer available, early exit", peer = $conn
    return

  # create new muxer for connection
  let muxer = s.muxers[muxerName].newMuxer(conn)
  s.connManager.storeMuxer(muxer)

  trace "found a muxer", name = muxerName, peer = $conn

  # install stream handler
  muxer.streamHandler = s.streamHandler

  # new stream for identify
  var stream = await muxer.newStream()

  defer:
    if not(isNil(stream)):
      await stream.close() # close identify stream

  # call muxer handler, this should
  # not end until muxer ends
  let handlerFut = muxer.handle()

  # do identify first, so that we have a
  # PeerInfo in case we didn't before
  await s.identify(stream)

  if isNil(conn.peerInfo):
    await muxer.close()
    raise newException(CatchableError,
      "unable to identify peer, aborting upgrade")

  # store it in muxed connections if we have a peer for it
  trace "adding muxer for peer", peer = conn.peerInfo.id
  s.connManager.storeMuxer(muxer, handlerFut) # update muxer with handler

proc disconnect*(s: Switch, peer: PeerInfo) {.async, gcsafe.} =
  if not peer.isNil:
    await s.connManager.dropPeer(peer.peerId)

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
      "unable to identify connection, stopping upgrade")

  trace "successfully upgraded outgoing connection", oid = sconn.oid

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

      # handle subsequent secure requests
      await ms.handle(sconn)

    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "ending secured handler", err = exc.msg

  if (await ms.select(conn)): # just handshake
    # add the secure handlers
    for k in s.secureManagers:
      ms.addHandler(k.codec, securedHandler)

  # handle un-secured connections
  # we handshaked above, set this ms handler as active
  await ms.handle(conn, active = true)

proc internalConnect(s: Switch,
                     peer: PeerInfo): Future[Connection] {.async.} =

  if s.peerInfo.peerId == peer.peerId:
    raise newException(CatchableError, "can't dial self!")

  let id = peer.id
  var conn: Connection
  let lock = s.dialLock.mgetOrPut(id, newAsyncLock())

  try:
    await lock.acquire()
    trace "about to dial peer", peer = id
    conn = s.connManager.selectConn(peer.peerId)
    if conn.isNil or (conn.closed or conn.atEof):
      trace "Dialing peer", peer = id
      for t in s.transports: # for each transport
        for a in peer.addrs: # for each address
          if t.handles(a):   # check if it can dial it
            trace "Dialing address", address = $a, peer = id
            try:
              conn = await t.dial(a)
              # make sure to assign the peer to the connection
              conn.peerInfo = peer

              conn.closeEvent.wait()
                .addCallback do(udata: pointer):
                  asyncCheck s.triggerHooks(
                    conn.peerInfo,
                    Lifecycle.Disconnected)

              asyncCheck s.triggerHooks(conn.peerInfo, Lifecycle.Connected)
              libp2p_dialed_peers.inc()
            except CancelledError as exc:
              trace "dialing canceled", exc = exc.msg
              raise
            except CatchableError as exc:
              trace "dialing failed", exc = exc.msg
              libp2p_failed_dials.inc()
              continue

            try:
              let uconn = await s.upgradeOutgoing(conn)
              s.connManager.storeOutgoing(uconn)
              asyncCheck s.triggerHooks(uconn.peerInfo, Lifecycle.Upgraded)
              conn = uconn
              trace "dial successful", oid = $conn.oid, peer = $conn.peerInfo
            except CatchableError as exc:
              if not(isNil(conn)):
                await conn.close()

              trace "Unable to establish outgoing link", exc = exc.msg
              raise exc

            if isNil(conn):
              libp2p_failed_upgrade.inc()
              continue
            break
    else:
      trace "Reusing existing connection", oid = $conn.oid,
                                           direction = $conn.dir,
                                           peer = $conn.peerInfo
  finally:
    if lock.locked():
      lock.release()

  if isNil(conn):
    raise newException(CatchableError,
      "Unable to establish outgoing link")

  if conn.closed or conn.atEof:
    await conn.close()
    raise newException(CatchableError,
      "Connection dead on arrival")

  doAssert(conn in s.connManager, "connection not tracked!")

  trace "dial successful", oid = $conn.oid,
                           peer = $conn.peerInfo

  await s.subscribePeer(peer)
  asyncCheck s.cleanupPubSubPeer(conn)

  trace "got connection", oid = $conn.oid,
                          direction = $conn.dir,
                          peer = $conn.peerInfo
  return conn

proc connect*(s: Switch, peer: PeerInfo) {.async.} =
  discard await s.internalConnect(peer)

proc dial*(s: Switch,
           peer: PeerInfo,
           proto: string):
           Future[Connection] {.async.} =
  let conn = await s.internalConnect(peer)
  let stream = await s.connManager.getMuxedStream(conn)

  proc cleanup() {.async.} =
    if not(isNil(stream)):
      await stream.close()

    if not(isNil(conn)):
      await conn.close()

  try:
    if isNil(stream):
      await conn.close()
      raise newException(CatchableError, "Couldn't get muxed stream")

    trace "Attempting to select remote", proto = proto,
                                         streamOid = $stream.oid,
                                         oid = $conn.oid
    if not await s.ms.select(stream, proto):
      await stream.close()
      raise newException(CatchableError, "Unable to select sub-protocol " & proto)

    return stream
  except CancelledError as exc:
    trace "dial canceled"
    await cleanup()
    raise exc
  except CatchableError as exc:
    trace "error dialing", exc = exc.msg
    await cleanup()
    raise exc

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
      conn.closeEvent.wait()
        .addCallback do(udata: pointer):
          asyncCheck s.triggerHooks(
            conn.peerInfo,
            Lifecycle.Disconnected)

      asyncCheck s.triggerHooks(conn.peerInfo, Lifecycle.Connected)
      await s.upgradeIncoming(conn) # perform upgrade on incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "Exception occurred in Switch.start", exc = exc.msg
    finally:
      await conn.close()

  var startFuts: seq[Future[void]]
  for t in s.transports: # for each transport
    for i, a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        var server = await t.listen(a, handle)
        s.peerInfo.addrs[i] = t.ma # update peer's address
        startFuts.add(server)

  if s.pubSub.isSome:
    await s.pubSub.get().start()

  debug "started libp2p node", peer = $s.peerInfo, addrs = s.peerInfo.addrs
  result = startFuts # listen for incoming connections

proc stop*(s: Switch) {.async.} =
  trace "stopping switch"

  # we want to report errors but we do not want to fail
  # or crash here, cos we need to clean possibly MANY items
  # and any following conn/transport won't be cleaned up
  if s.pubSub.isSome:
    await s.pubSub.get().stop()

  # close and cleanup all connections
  await s.connManager.close()

  for t in s.transports:
    try:
        await t.close()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "error cleaning up transports"

  trace "switch stopped"

proc subscribePeerInternal(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  ## Subscribe to pub sub peer
  if s.pubSub.isSome and not(s.pubSub.get().connected(peerInfo)):
    trace "about to subscribe to pubsub peer", peer = peerInfo.shortLog()
    var stream: Connection
    try:
      stream = await s.connManager.getMuxedStream(peerInfo.peerId)
      if isNil(stream):
        trace "unable to subscribe to peer", peer = peerInfo.shortLog
        return

      if not await s.ms.select(stream, s.pubSub.get().codec):
        if not(isNil(stream)):
          await stream.close()
        return

      s.pubSub.get().subscribePeer(stream)
      await stream.closeEvent.wait()
    except CancelledError as exc:
      if not(isNil(stream)):
        await stream.close()

      raise exc
    except CatchableError as exc:
      trace "exception in subscribe to peer", peer = peerInfo.shortLog,
                                              exc = exc.msg
      if not(isNil(stream)):
        await stream.close()

proc pubsubMonitor(s: Switch, peer: PeerInfo) {.async.} =
  ## while peer connected maintain a
  ## pubsub connection as well
  ##

  var tries = 0
  # var backoffFactor = 5 # up to ~10 mins
  var backoff = 1.seconds
  while s.isConnected(peer) and
    tries < MaxPubsubReconnectAttempts:
    try:
        debug "subscribing to pubsub peer", peer = $peer
        await s.subscribePeerInternal(peer)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in pubsub monitor", peer = $peer, exc = exc.msg
    finally:
      debug "awaiting backoff period before reconnecting", peer = $peer, backoff, tries
      await sleepAsync(backoff) # allow the peer to cooldown
      # backoff = backoff * backoffFactor
      tries.inc()

  trace "exiting pubsub monitor", peer = $peer

proc subscribePeer*(s: Switch, peerInfo: PeerInfo) {.async, gcsafe.} =
  if peerInfo.peerId notin s.pubsubMonitors:
    s.pubsubMonitors[peerInfo.peerId] = s.pubsubMonitor(peerInfo)

proc subscribe*(s: Switch, topic: string,
                handler: TopicHandler) {.async.} =
  ## subscribe to a pubsub topic
  ##

  if s.pubSub.isNone:
    raise newNoPubSubException()

  await s.pubSub.get().subscribe(topic, handler)

proc unsubscribe*(s: Switch, topics: seq[TopicPair]) {.async.} =
  ## unsubscribe from topics
  ##

  if s.pubSub.isNone:
    raise newNoPubSubException()

  await s.pubSub.get().unsubscribe(topics)

proc unsubscribeAll*(s: Switch, topic: string) {.async.} =
  ## unsubscribe from topics
  if s.pubSub.isNone:
    raise newNoPubSubException()

  await s.pubSub.get().unsubscribeAll(topic)

proc publish*(s: Switch,
              topic: string,
              data: seq[byte],
              timeout: Duration = InfiniteDuration): Future[int] {.async.} =
  ## pubslish to pubsub topic
  ##

  if s.pubSub.isNone:
    raise newNoPubSubException()

  return await s.pubSub.get().publish(topic, data, timeout)

proc addValidator*(s: Switch,
                   topics: varargs[string],
                   hook: ValidatorHandler) =
  ## add validator
  ##

  if s.pubSub.isNone:
    raise newNoPubSubException()

  s.pubSub.get().addValidator(topics, hook)

proc removeValidator*(s: Switch,
                      topics: varargs[string],
                      hook: ValidatorHandler) =
  ## pubslish to pubsub topic
  ##

  if s.pubSub.isNone:
    raise newNoPubSubException()

  s.pubSub.get().removeValidator(topics, hook)

proc muxerHandler(s: Switch, muxer: Muxer) {.async, gcsafe.} =
  var stream = await muxer.newStream()
  defer:
    if not(isNil(stream)):
      await stream.close()

  try:
    # once we got a muxed connection, attempt to
    # identify it
    await s.identify(stream)
    if isNil(stream.peerInfo):
      await muxer.close()
      return

    muxer.connection.peerInfo = stream.peerInfo

    # store incoming connection
    s.connManager.storeIncoming(muxer.connection)

    # store muxer and muxed connection
    s.connManager.storeMuxer(muxer)

    trace "got new muxer", peer = $muxer.connection.peerInfo
    asyncCheck s.triggerHooks(muxer.connection.peerInfo, Lifecycle.Upgraded)

    # try establishing a pubsub connection
    await s.subscribePeer(muxer.connection.peerInfo)
    asyncCheck s.cleanupPubSubPeer(muxer.connection)

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
    connManager: ConnManager.init(),
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

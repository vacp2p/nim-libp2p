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

type
    UpgradeFailedError* = object of CatchableError
    DialFailedError* = object of CatchableError

    ConnEventKind* {.pure.} = enum
      Connected, # A connection was made and securely upgraded - there may be
                 # more than one concurrent connection thus more than one upgrade
                 # event per peer.
      Disconnected # Peer disconnected - this event is fired once per upgrade
                   # when the associated connection is terminated.

    ConnEvent* = object
      case kind*: ConnEventKind
      of ConnEventKind.Connected:
        incoming*: bool
      else:
        discard

    ConnEventHandler* =
      proc(peerId: PeerID, event: ConnEvent): Future[void] {.gcsafe.}

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
      dialLock: Table[PeerID, AsyncLock]
      ConnEvents: Table[ConnEventKind, HashSet[ConnEventHandler]]

proc addConnEventHandler*(s: Switch,
                          handler: ConnEventHandler, kind: ConnEventKind) =
  ## Add peer event handler - handlers must not raise exceptions!
  if isNil(handler): return
  s.ConnEvents.mgetOrPut(kind, initHashSet[ConnEventHandler]()).incl(handler)

proc removeConnEventHandler*(s: Switch,
                             handler: ConnEventHandler, kind: ConnEventKind) =
  s.ConnEvents.withValue(kind, handlers) do:
    handlers[].excl(handler)

proc triggerConnEvent(s: Switch, peerId: PeerID, event: ConnEvent) {.async, gcsafe.} =
  try:
    if event.kind in s.ConnEvents:
      var ConnEvents: seq[Future[void]]
      for h in s.ConnEvents[event.kind]:
        ConnEvents.add(h(peerId, event))

      checkFutures(await allFinished(ConnEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "Exception in triggerConnEvents",
      msg = exc.msg, peerId, event = $event

proc isConnected*(s: Switch, peerId: PeerID): bool =
  ## returns true if the peer has one or more
  ## associated connections (sockets)
  ##

  peerId in s.connManager

proc secure(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  if s.secureManagers.len <= 0:
    raise newException(UpgradeFailedError, "No secure managers registered!")

  let codec = await s.ms.select(conn, s.secureManagers.mapIt(it.codec))
  if codec.len == 0:
    raise newException(UpgradeFailedError, "Unable to negotiate a secure channel!")

  trace "Securing connection", conn, codec
  let secureProtocol = s.secureManagers.filterIt(it.codec == codec)

  # ms.select should deal with the correctness of this
  # let's avoid duplicating checks but detect if it fails to do it properly
  doAssert(secureProtocol.len > 0)

  return await secureProtocol[0].secure(conn, true)

proc identify(s: Switch, conn: Connection) {.async, gcsafe.} =
  ## identify the connection

  if (await s.ms.select(conn, s.identity.codec)):
    let info = await s.identity.identify(conn, conn.peerInfo)

    if info.pubKey.isNone and isNil(conn):
      raise newException(UpgradeFailedError,
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

    trace "identified remote peer", conn, peerInfo = shortLog(conn.peerInfo)

proc identify(s: Switch, muxer: Muxer) {.async, gcsafe.} =
  # new stream for identify
  var stream = await muxer.newStream()

  defer:
    if not(isNil(stream)):
      await stream.close() # close identify stream

  # do identify first, so that we have a
  # PeerInfo in case we didn't before
  await s.identify(stream)

proc mux(s: Switch, conn: Connection): Future[Muxer] {.async, gcsafe.} =
  ## mux incoming connection

  trace "Muxing connection", conn
  if s.muxers.len == 0:
    warn "no muxers registered, skipping upgrade flow", conn
    return

  let muxerName = await s.ms.select(conn, toSeq(s.muxers.keys()))
  if muxerName.len == 0 or muxerName == "na":
    debug "no muxer available, early exit", conn
    return

  trace "Found a muxer", conn, muxerName

  # create new muxer for connection
  let muxer = s.muxers[muxerName].newMuxer(conn)

  # install stream handler
  muxer.streamHandler = s.streamHandler

  s.connManager.storeOutgoing(conn)
  s.connManager.storeMuxer(muxer)

  # start muxer read loop - the future will complete when loop ends
  let handlerFut = muxer.handle()

  # store it in muxed connections if we have a peer for it
  s.connManager.storeMuxer(muxer, handlerFut) # update muxer with handler

  return muxer

proc disconnect*(s: Switch, peerId: PeerID): Future[void] {.gcsafe.} =
  s.connManager.dropPeer(peerId)

proc upgradeOutgoing(s: Switch, conn: Connection): Future[Connection] {.async, gcsafe.} =
  trace "Upgrading outgoing connection", conn

  let sconn = await s.secure(conn) # secure the connection
  if isNil(sconn):
    raise newException(UpgradeFailedError,
      "unable to secure connection, stopping upgrade")

  if sconn.peerInfo.isNil:
    raise newException(UpgradeFailedError,
      "current version of nim-libp2p requires that secure protocol negotiates peerid")

  let muxer = await s.mux(sconn) # mux it if possible
  if muxer == nil:
    # TODO this might be relaxed in the future
    raise newException(UpgradeFailedError,
      "a muxer is required for outgoing connections")

  try:
    await s.identify(muxer)
  except CatchableError as exc:
    # Identify is non-essential, though if it fails, it might indicate that
    # the connection was closed already - this will be picked up by the read
    # loop
    debug "Could not identify connection", conn, msg = exc.msg

  if isNil(sconn.peerInfo):
    await sconn.close()
    raise newException(UpgradeFailedError,
      "No peerInfo for connection, stopping upgrade")

  trace "Upgraded outgoing connection", conn, sconn

  return sconn

proc upgradeIncoming(s: Switch, conn: Connection) {.async, gcsafe.} =
  trace "Upgrading incoming connection", conn
  let ms = newMultistream()

  # secure incoming connections
  proc securedHandler (conn: Connection,
                       proto: string)
                       {.async, gcsafe, closure.} =
    trace "Starting secure handler", conn
    let secure = s.secureManagers.filterIt(it.codec == proto)[0]

    try:
      var sconn = await secure.secure(conn, false)
      if isNil(sconn):
        return

      defer:
        await sconn.close()

      # add the muxer
      for muxer in s.muxers.values:
        ms.addHandler(muxer.codecs, muxer)

      # add the mounted protocols
      # notice this should be kept in sync ...
      for handler in s.ms.handlers:
        ms.handlers &= handler

      # handle subsequent secure requests
      await ms.handle(sconn)

    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Exception in secure handler", msg = exc.msg, conn

    trace "Stopped secure handler", conn

  if (await ms.select(conn)): # just handshake
    # add the secure handlers
    for k in s.secureManagers:
      ms.addHandler(k.codec, securedHandler)

  # handle un-secured connections
  # we handshaked above, set this ms handler as active
  await ms.handle(conn, active = true)

proc internalConnect(s: Switch,
                     peerId: PeerID,
                     addrs: seq[MultiAddress]): Future[Connection] {.async.} =
  if s.peerInfo.peerId == peerId:
    raise newException(CatchableError, "can't dial self!")

  var conn: Connection
  # Ensure there's only one in-flight attempt per peer
  let lock = s.dialLock.mgetOrPut(peerId, newAsyncLock())
  try:
    await lock.acquire()

    # Check if we have a connection already and try to reuse it
    conn = s.connManager.selectConn(peerId)
    if conn != nil:
      if conn.atEof or conn.closed:
        # This connection should already have been removed from the connection
        # manager - it's essentially a bug that we end up here - we'll fail
        # for now, hoping that this will clean themselves up later...
        warn "dead connection in connection manager", conn
        await conn.close()
        raise newException(DialFailedError, "Zombie connection encountered")

      trace "Reusing existing connection", conn, direction = $conn.dir

      return conn

    trace "Dialing peer", peerId
    for t in s.transports: # for each transport
      for a in addrs: # for each address
        if t.handles(a):   # check if it can dial it
          trace "Dialing address", address = $a, peerId
          let dialed = try:
              await t.dial(a)
            except CancelledError as exc:
              trace "Dialing canceled", msg = exc.msg, peerId
              raise exc
            except CatchableError as exc:
              trace "Dialing failed", msg = exc.msg, peerId
              libp2p_failed_dials.inc()
              continue # Try the next address

          # make sure to assign the peer to the connection
          dialed.peerInfo = PeerInfo.init(peerId, addrs)

          libp2p_dialed_peers.inc()

          let upgraded = try:
              await s.upgradeOutgoing(dialed)
            except CatchableError as exc:
              # If we failed to establish the connection through one transport,
              # we won't succeeed through another - no use in trying again
              await dialed.close()
              debug "Upgrade failed", msg = exc.msg, peerId
              if exc isnot CancelledError:
                libp2p_failed_upgrade.inc()
              raise exc

          doAssert not isNil(upgraded), "connection died after upgradeOutgoing"

          conn = upgraded
          trace "Dial successful", conn, peerInfo = conn.peerInfo
          break
  finally:
    if lock.locked():
      lock.release()

  if isNil(conn): # None of the addresses connected
    raise newException(CatchableError, "Unable to establish outgoing link")

  if conn.closed():
    # This can happen if one of the peer event handlers deems the peer
    # unworthy and disconnects it
    raise newLPStreamClosedError()

  await s.triggerConnEvent(
    peerId, ConnEvent(kind: ConnEventKind.Connected, incoming: false))

  proc peerCleanup() {.async.} =
    try:
      await conn.closeEvent.wait()
      await s.triggerConnEvent(peerId,
                               ConnEvent(kind: ConnEventKind.Disconnected))
    except CatchableError as exc:
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError and should handle other errors
      warn "Unexpected exception in switch peer connect cleanup",
        conn, msg = exc.msg

  # All the errors are handled inside `cleanup()` procedure.
  asyncSpawn peerCleanup()

  return conn

proc connect*(s: Switch, peerId: PeerID, addrs: seq[MultiAddress]) {.async.} =
  discard await s.internalConnect(peerId, addrs)

proc negotiateStream(s: Switch, conn: Connection, protos: seq[string]): Future[Connection] {.async.} =
  trace "Negotiating stream", conn, protos
  let selected = await s.ms.select(conn, protos)
  if not protos.contains(selected):
    await conn.close()
    raise newException(DialFailedError, "Unable to select sub-protocol " & $protos)

  return conn

proc dial*(s: Switch,
           peerId: PeerID,
           protos: seq[string]): Future[Connection] {.async.} =
  trace "Dialling (existing)", peerId, protos
  let stream = await s.connManager.getMuxedStream(peerId)
  if stream.isNil:
    raise newException(DialFailedError, "Couldn't get muxed stream")

  return await s.negotiateStream(stream, protos)

proc dial*(s: Switch,
           peerId: PeerID,
           proto: string): Future[Connection] = dial(s, peerId, @[proto])

proc dial*(s: Switch,
           peerId: PeerID,
           addrs: seq[MultiAddress],
           protos: seq[string]):
           Future[Connection] {.async.} =
  trace "Dialling (new)", peerId, protos
  let conn = await s.internalConnect(peerId, addrs)
  trace "Opening stream", conn
  let stream = await s.connManager.getMuxedStream(conn)

  proc cleanup() {.async.} =
    if not(isNil(stream)):
      await stream.close()

    if not(isNil(conn)):
      await conn.close()

  try:
    if isNil(stream):
      await conn.close()
      raise newException(DialFailedError, "Couldn't get muxed stream")

    return await s.negotiateStream(stream, protos)
  except CancelledError as exc:
    trace "Dial canceled", conn
    await cleanup()
    raise exc
  except CatchableError as exc:
    trace "Error dialing", conn, msg = exc.msg
    await cleanup()
    raise exc

proc dial*(s: Switch,
           peerId: PeerID,
           addrs: seq[MultiAddress],
           proto: string):
           Future[Connection] = dial(s, peerId, addrs, @[proto])

proc mount*[T: LPProtocol](s: Switch, proto: T) {.gcsafe.} =
  if isNil(proto.handler):
    raise newException(CatchableError,
      "Protocol has to define a handle method or proc")

  if proto.codec.len == 0:
    raise newException(CatchableError,
      "Protocol has to define a codec string")

  s.ms.addHandler(proto.codecs, proto)

proc start*(s: Switch): Future[seq[Future[void]]] {.async, gcsafe.} =
  trace "starting switch for peer", peerInfo = s.peerInfo

  proc handle(conn: Connection): Future[void] {.async, closure, gcsafe.} =
    trace "Incoming connection", conn
    try:
      await s.upgradeIncoming(conn) # perform upgrade on incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "Exception occurred in incoming handler", conn, msg = exc.msg
    finally:
      await conn.close()
    trace "Connection handler done", conn

  var startFuts: seq[Future[void]]
  for t in s.transports: # for each transport
    for i, a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        var server = await t.listen(a, handle)
        s.peerInfo.addrs[i] = t.ma # update peer's address
        startFuts.add(server)

  debug "Started libp2p node", peer = s.peerInfo
  result = startFuts # listen for incoming connections

proc stop*(s: Switch) {.async.} =
  trace "Stopping switch"

  # close and cleanup all connections
  await s.connManager.close()

  for t in s.transports:
    try:
        await t.close()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "error cleaning up transports", msg = exc.msg

  trace "Switch stopped"

proc muxerHandler(s: Switch, muxer: Muxer) {.async, gcsafe.} =
  let
    conn = muxer.connection

  if conn.peerInfo.isNil:
    warn "This version of nim-libp2p requires secure protocol to negotiate peerid"
    await muxer.close()
    return

  # store incoming connection
  s.connManager.storeIncoming(conn)

  # store muxer and muxed connection
  s.connManager.storeMuxer(muxer)

  try:
    await s.identify(muxer)
  except CatchableError as exc:
    # Identify is non-essential, though if it fails, it might indicate that
    # the connection was closed already - this will be picked up by the read
    # loop
    debug "Could not identify connection", conn, msg = exc.msg

  try:
    let peerId = conn.peerInfo.peerId

    proc peerCleanup() {.async.} =
      try:
        await muxer.connection.closeEvent.wait()
        await s.triggerConnEvent(peerId,
                                 ConnEvent(kind: ConnEventKind.Disconnected))
      except CatchableError as exc:
        # This is top-level procedure which will work as separate task, so it
        # do not need to propogate CancelledError and shouldn't leak others
        debug "Unexpected exception in switch muxer cleanup",
          conn, msg = exc.msg

    proc peerStartup() {.async.} =
      try:
        await s.triggerConnEvent(peerId,
                                 ConnEvent(kind: ConnEventKind.Connected,
                                           incoming: true))
      except CatchableError as exc:
        # This is top-level procedure which will work as separate task, so it
        # do not need to propogate CancelledError and shouldn't leak others
        debug "Unexpected exception in switch muxer startup",
          conn, msg = exc.msg

    # All the errors are handled inside `peerStartup()` procedure.
    asyncSpawn peerStartup()

    # All the errors are handled inside `peerCleanup()` procedure.
    asyncSpawn peerCleanup()

  except CancelledError as exc:
    await muxer.close()
    raise exc
  except CatchableError as exc:
    await muxer.close()
    libp2p_failed_upgrade.inc()
    trace "Exception in muxer handler", conn, msg = exc.msg

proc newSwitch*(peerInfo: PeerInfo,
                transports: seq[Transport],
                identity: Identify,
                muxers: Table[string, MuxerProvider],
                secureManagers: openarray[Secure] = []): Switch =
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
  result.streamHandler = proc(conn: Connection) {.async, gcsafe.} = # noraises
    trace "Starting stream handler", conn
    try:
      await s.ms.handle(conn) # handle incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in stream handler", conn, msg = exc.msg
    finally:
      await conn.close()
    trace "Stream handler done", conn

  result.mount(identity)
  for key, val in muxers:
    val.streamHandler = result.streamHandler
    val.muxerHandler = proc(muxer: Muxer): Future[void] =
      s.muxerHandler(muxer)

proc isConnected*(s: Switch, peerInfo: PeerInfo): bool
  {.deprecated: "Use PeerID version".} =
  not isNil(peerInfo) and isConnected(s, peerInfo.peerId)

proc disconnect*(s: Switch, peerInfo: PeerInfo): Future[void]
  {.deprecated: "Use PeerID version", gcsafe.} =
  disconnect(s, peerInfo.peerId)

proc connect*(s: Switch, peerInfo: PeerInfo): Future[void]
  {.deprecated: "Use PeerID version".} =
  connect(s, peerInfo.peerId, peerInfo.addrs)

proc dial*(s: Switch,
           peerInfo: PeerInfo,
           proto: string):
           Future[Connection]
  {.deprecated: "Use PeerID version".} =
  dial(s, peerInfo.peerId, peerInfo.addrs, proto)

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
       utils/semaphore,
       connmanager,
       peerid,
       errors

export connmanager

logScope:
  topics = "libp2p switch"

#TODO: General note - use a finite state machine to manage the different
# steps of connections establishing and upgrading. This makes everything
# more robust and less prone to ordering attacks - i.e. muxing can come if
# and only if the channel has been secured (i.e. if a secure manager has been
# previously provided)

declareCounter(libp2p_total_dial_attempts, "total attempted dials")
declareCounter(libp2p_successful_dials, "dialed successful peers")
declareCounter(libp2p_failed_dials, "failed dials")
declareCounter(libp2p_failed_upgrades_incoming, "incoming connections failed upgrades")
declareCounter(libp2p_failed_upgrades_outgoing, "outgoing connections failed upgrades")

const
  ConcurrentUpgrades* = 4

type
    UpgradeFailedError* = object of CatchableError
    DialFailedError* = object of CatchableError

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
      acceptFuts: seq[Future[void]]

proc addConnEventHandler*(s: Switch,
                          handler: ConnEventHandler,
                          kind: ConnEventKind) =
  s.connManager.addConnEventHandler(handler, kind)

proc removeConnEventHandler*(s: Switch,
                             handler: ConnEventHandler,
                             kind: ConnEventKind) =
  s.connManager.removeConnEventHandler(handler, kind)

proc addPeerEventHandler*(s: Switch,
                          handler: PeerEventHandler,
                          kind: PeerEventKind) =
  s.connManager.addPeerEventHandler(handler, kind)

proc removePeerEventHandler*(s: Switch,
                             handler: PeerEventHandler,
                             kind: PeerEventKind) =
  s.connManager.removePeerEventHandler(handler, kind)

proc disconnect*(s: Switch, peerId: PeerID) {.async, gcsafe.}

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
  if stream == nil:
    return

  try:
    await s.identify(stream)
  finally:
    await stream.closeWithEOF()

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

  # store it in muxed connections if we have a peer for it
  s.connManager.storeMuxer(muxer, muxer.handle()) # store muxer and start read loop

  try:
    await s.identify(muxer)
  except CatchableError as exc:
    # Identify is non-essential, though if it fails, it might indicate that
    # the connection was closed already - this will be picked up by the read
    # loop
    debug "Could not identify connection", conn, msg = exc.msg

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

  if sconn.closed() or isNil(sconn.peerInfo):
    await sconn.close()
    raise newException(UpgradeFailedError,
      "Connection closed or missing peer info, stopping upgrade")

  trace "Upgraded outgoing connection", conn, sconn

  return sconn

proc upgradeIncoming(s: Switch, incomingConn: Connection) {.async, gcsafe.} = # noraises
  trace "Upgrading incoming connection", incomingConn
  let ms = newMultistream()

  # secure incoming connections
  proc securedHandler(conn: Connection,
                      proto: string)
                      {.async, gcsafe, closure.} =
    trace "Starting secure handler", conn
    let secure = s.secureManagers.filterIt(it.codec == proto)[0]

    var cconn = conn
    try:
      var sconn = await secure.secure(cconn, false)
      if isNil(sconn):
        return

      cconn = sconn
      # add the muxer
      for muxer in s.muxers.values:
        ms.addHandler(muxer.codecs, muxer)

      # handle subsequent secure requests
      await ms.handle(cconn)
    except CatchableError as exc:
      debug "Exception in secure handler during incoming upgrade", msg = exc.msg, conn
      if not cconn.upgraded.finished:
        cconn.upgraded.fail(exc)
    finally:
      if not isNil(cconn):
        await cconn.close()

    trace "Stopped secure handler", conn

  try:
    if (await ms.select(incomingConn)): # just handshake
      # add the secure handlers
      for k in s.secureManagers:
        ms.addHandler(k.codec, securedHandler)

    # handle un-secured connections
    # we handshaked above, set this ms handler as active
    await ms.handle(incomingConn, active = true)
  except CatchableError as exc:
    debug "Exception upgrading incoming", exc = exc.msg
    if not incomingConn.upgraded.finished:
      incomingConn.upgraded.fail(exc)
  finally:
    await incomingConn.close()

proc dialAndUpgrade(s: Switch,
                    peerId: PeerID,
                    addrs: seq[MultiAddress]):
                    Future[Connection] {.async.} =
  debug "Dialing peer", peerId
  for t in s.transports: # for each transport
    for a in addrs:      # for each address
      if t.handles(a):   # check if it can dial it
        trace "Dialing address", address = $a, peerId
        let dialed = try:
            libp2p_total_dial_attempts.inc()
            await t.dial(a)
          except CancelledError as exc:
            debug "Dialing canceled", msg = exc.msg, peerId
            raise exc
          except CatchableError as exc:
            debug "Dialing failed", msg = exc.msg, peerId
            libp2p_failed_dials.inc()
            continue # Try the next address

        # make sure to assign the peer to the connection
        dialed.peerInfo = PeerInfo.init(peerId, addrs)

        libp2p_successful_dials.inc()

        let conn = try:
            await s.upgradeOutgoing(dialed)
          except CatchableError as exc:
            # If we failed to establish the connection through one transport,
            # we won't succeeded through another - no use in trying again
            await dialed.close()
            debug "Upgrade failed", msg = exc.msg, peerId
            if exc isnot CancelledError:
              libp2p_failed_upgrades_outgoing.inc()
            raise exc

        doAssert not isNil(conn), "connection died after upgradeOutgoing"
        debug "Dial successful", conn, peerInfo = conn.peerInfo
        return conn

proc internalConnect(s: Switch,
                     peerId: PeerID,
                     addrs: seq[MultiAddress]): Future[Connection] {.async.} =
  if s.peerInfo.peerId == peerId:
    raise newException(CatchableError, "can't dial self!")

  # Ensure there's only one in-flight attempt per peer
  let lock = s.dialLock.mgetOrPut(peerId, newAsyncLock())
  try:
    await lock.acquire()

    # Check if we have a connection already and try to reuse it
    var conn = s.connManager.selectConn(peerId)
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

    conn = await s.dialAndUpgrade(peerId, addrs)
    if isNil(conn): # None of the addresses connected
      raise newException(DialFailedError, "Unable to establish outgoing link")

    # We already check for this in Connection manager
    # but a disconnect could have happened right after
    # we've added the connection so we check again
    # to prevent races due to that.
    if conn.closed() or conn.atEof():
      # This can happen when the other ends drops us
      # before we get a chance to return the connection
      # back to the dialer.
      trace "Connection dead on arrival", conn
      raise newLPStreamClosedError()

    return conn
  finally:
    if lock.locked():
      lock.release()

proc connect*(s: Switch, peerId: PeerID, addrs: seq[MultiAddress]) {.async.} =
  discard await s.internalConnect(peerId, addrs)

proc negotiateStream(s: Switch, conn: Connection, protos: seq[string]): Future[Connection] {.async.} =
  trace "Negotiating stream", conn, protos
  let selected = await s.ms.select(conn, protos)
  if not protos.contains(selected):
    await conn.closeWithEOF()
    raise newException(DialFailedError, "Unable to select sub-protocol " & $protos)

  return conn

proc dial*(s: Switch,
           peerId: PeerID,
           protos: seq[string]): Future[Connection] {.async.} =
  trace "Dialing (existing)", peerId, protos
  let stream = await s.connManager.getStream(peerId)
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
  trace "Dialing (new)", peerId, protos
  let conn = await s.internalConnect(peerId, addrs)
  trace "Opening stream", conn
  let stream = await s.connManager.getStream(conn)

  proc cleanup() {.async.} =
    if not(isNil(stream)):
      await stream.closeWithEOF()

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
    debug "Error dialing", conn, msg = exc.msg
    await cleanup()
    raise exc

proc dial*(s: Switch,
           peerId: PeerID,
           addrs: seq[MultiAddress],
           proto: string):
           Future[Connection] = dial(s, peerId, addrs, @[proto])

proc mount*[T: LPProtocol](s: Switch, proto: T, matcher: Matcher = nil) {.gcsafe.} =
  if isNil(proto.handler):
    raise newException(CatchableError,
      "Protocol has to define a handle method or proc")

  if proto.codec.len == 0:
    raise newException(CatchableError,
      "Protocol has to define a codec string")

  s.ms.addHandler(proto.codecs, proto, matcher)

proc upgradeMonitor(conn: Connection, upgrades: AsyncSemaphore) {.async.} =
  ## monitor connection for upgrades
  ##
  try:
    # Since we don't control the flow of the
    # upgrade, this timeout guarantees that a
    # "hanged" remote doesn't hold the upgrade
    # forever
    await conn.upgraded.wait(30.seconds) # wait for connection to be upgraded
    trace "Connection upgrade succeeded"
  except CatchableError as exc:
    libp2p_failed_upgrades_incoming.inc()
    if not isNil(conn):
      await conn.close()

    trace "Exception awaiting connection upgrade", exc = exc.msg, conn
  finally:
    upgrades.release() # don't forget to release the slot!

proc accept(s: Switch, transport: Transport) {.async.} = # noraises
  ## switch accept loop, ran for every transport
  ##

  let upgrades = AsyncSemaphore.init(ConcurrentUpgrades)
  while transport.running:
    var conn: Connection
    try:
      debug "About to accept incoming connection"
      # remember to always release the slot when
      # the upgrade succeeds or fails, this is
      # currently done by the `upgradeMonitor`
      await upgrades.acquire()        # first wait for an upgrade slot to become available
      conn = await transport.accept() # next attempt to get a connection
      if isNil(conn):
        # A nil connection means that we might have hit a
        # file-handle limit (or another non-fatal error),
        # we can get one on the next try, but we should
        # be careful to not end up in a thigh loop that
        # will starve the main event loop, thus we sleep
        # here before retrying.
        trace "Unable to get a connection, sleeping"
        await sleepAsync(100.millis) # TODO: should be configurable?
        upgrades.release()
        continue

      debug "Accepted an incoming connection", conn
      asyncSpawn upgradeMonitor(conn, upgrades)
      asyncSpawn s.upgradeIncoming(conn)
    except CancelledError as exc:
      trace "releasing semaphore on cancellation"
      upgrades.release() # always release the slot
    except CatchableError as exc:
      debug "Exception in accept loop, exiting", exc = exc.msg
      upgrades.release() # always release the slot
      if not isNil(conn):
        await conn.close()
      return

proc start*(s: Switch): Future[seq[Future[void]]] {.async, gcsafe.} =
  trace "starting switch for peer", peerInfo = s.peerInfo
  var startFuts: seq[Future[void]]
  for t in s.transports: # for each transport
    for i, a in s.peerInfo.addrs:
      if t.handles(a): # check if it handles the multiaddr
        var server = t.start(a)
        s.peerInfo.addrs[i] = t.ma # update peer's address
        s.acceptFuts.add(s.accept(t))
        startFuts.add(server)

  debug "Started libp2p node", peer = s.peerInfo
  return startFuts # listen for incoming connections

proc stop*(s: Switch) {.async.} =
  trace "Stopping switch"

  # close and cleanup all connections
  await s.connManager.close()

  for t in s.transports:
    try:
      await t.stop()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      warn "error cleaning up transports", msg = exc.msg

  try:
    await allFutures(s.acceptFuts)
      .wait(1.seconds)
  except CatchableError as exc:
    trace "Exception while stopping accept loops", exc = exc.msg

  # check that all futures were properly
  # stopped and otherwise cancel them
  for a in s.acceptFuts:
    if not a.finished:
      a.cancel()

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
  except IdentifyError as exc:
    # Identify is non-essential, though if it fails, it might indicate that
    # the connection was closed already - this will be picked up by the read
    # loop
    debug "Could not identify connection", conn, msg = exc.msg
  except LPStreamClosedError as exc:
    debug "Identify stream closed", conn, msg = exc.msg
  except LPStreamEOFError as exc:
    debug "Identify stream EOF", conn, msg = exc.msg
  except CancelledError as exc:
    await muxer.close()
    raise exc
  except CatchableError as exc:
    await muxer.close()
    trace "Exception in muxer handler", conn, msg = exc.msg

proc newSwitch*(peerInfo: PeerInfo,
                transports: seq[Transport],
                identity: Identify,
                muxers: Table[string, MuxerProvider],
                secureManagers: openarray[Secure] = []): Switch =
  if secureManagers.len == 0:
    raise (ref CatchableError)(msg: "Provide at least one secure manager")

  let switch = Switch(
    peerInfo: peerInfo,
    ms: newMultistream(),
    transports: transports,
    connManager: ConnManager.init(),
    identity: identity,
    muxers: muxers,
    secureManagers: @secureManagers,
  )

  switch.streamHandler = proc(conn: Connection) {.async, gcsafe.} = # noraises
    trace "Starting stream handler", conn
    try:
      await switch.ms.handle(conn) # handle incoming connection
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in stream handler", conn, msg = exc.msg
    finally:
      await conn.closeWithEOF()
    trace "Stream handler done", conn

  switch.mount(identity)
  for key, val in muxers:
    val.streamHandler = switch.streamHandler
    val.muxerHandler = proc(muxer: Muxer): Future[void] =
      switch.muxerHandler(muxer)

  return switch

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

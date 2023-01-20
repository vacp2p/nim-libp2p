# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## The switch is the core of libp2p, which brings together the
## transports, the connection manager, the upgrader and other
## parts to allow programs to use libp2p

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[tables,
            options,
            sequtils,
            sets,
            oids,
            sugar,
            math]

import chronos,
       chronicles,
       metrics

import stream/connection,
       transports/transport,
       upgrademngrs/[upgrade, muxedupgrade],
       multistream,
       multiaddress,
       protocols/protocol,
       protocols/secure/secure,
       peerinfo,
       protocols/identify,
       muxers/muxer,
       utils/semaphore,
       connmanager,
       nameresolving/nameresolver,
       peerid,
       peerstore,
       errors,
       utility,
       dialer

export connmanager, upgrade, dialer, peerstore

logScope:
  topics = "libp2p switch"

#TODO: General note - use a finite state machine to manage the different
# steps of connections establishing and upgrading. This makes everything
# more robust and less prone to ordering attacks - i.e. muxing can come if
# and only if the channel has been secured (i.e. if a secure manager has been
# previously provided)

declareCounter(libp2p_failed_upgrades_incoming, "incoming connections failed upgrades")

const
  ConcurrentUpgrades* = 4

type
    Switch* {.public.} = ref object of Dial
      peerInfo*: PeerInfo
      connManager*: ConnManager
      transports*: seq[Transport]
      ms*: MultistreamSelect
      acceptFuts: seq[Future[void]]
      dialer*: Dial
      peerStore*: PeerStore
      nameResolver*: NameResolver
      started: bool
      services*: seq[Service]

    Service* = ref object of RootObj
      inUse: bool


method setup*(self: Service, switch: Switch): Future[bool] {.base, async, gcsafe.} =
  if self.inUse:
    warn "service setup has already been called"
    return false
  self.inUse = true
  return true

method run*(self: Service, switch: Switch) {.base, async, gcsafe.} =
  doAssert(false, "Not implemented!")

method stop*(self: Service, switch: Switch): Future[bool] {.base, async, gcsafe.} =
  if not self.inUse:
    warn "service is already stopped"
    return false
  self.inUse = false
  return true

proc addConnEventHandler*(s: Switch,
                          handler: ConnEventHandler,
                          kind: ConnEventKind) {.public.} =
  ## Adds a ConnEventHandler, which will be triggered when
  ## a connection to a peer is created or dropped.
  ## There may be multiple connections per peer.
  ##
  ## The handler should not raise.
  s.connManager.addConnEventHandler(handler, kind)

proc removeConnEventHandler*(s: Switch,
                             handler: ConnEventHandler,
                             kind: ConnEventKind) {.public.} =
  s.connManager.removeConnEventHandler(handler, kind)

proc addPeerEventHandler*(s: Switch,
                          handler: PeerEventHandler,
                          kind: PeerEventKind) {.public.} =
  ## Adds a PeerEventHandler, which will be triggered when
  ## a peer connects or disconnects from us.
  ##
  ## The handler should not raise.
  s.connManager.addPeerEventHandler(handler, kind)

proc removePeerEventHandler*(s: Switch,
                             handler: PeerEventHandler,
                             kind: PeerEventKind) {.public.} =
  s.connManager.removePeerEventHandler(handler, kind)

method addTransport*(s: Switch, t: Transport) =
  s.transports &= t
  s.dialer.addTransport(t)

proc connectedPeers*(s: Switch, dir: Direction): seq[PeerId] =
  s.connManager.connectedPeers(dir)

proc isConnected*(s: Switch, peerId: PeerId): bool {.public.} =
  ## returns true if the peer has one or more
  ## associated connections
  ##

  peerId in s.connManager

proc disconnect*(s: Switch, peerId: PeerId): Future[void] {.gcsafe, public.} =
  ## Disconnect from a peer, waiting for the connection(s) to be dropped
  s.connManager.dropPeer(peerId)

method connect*(
  s: Switch,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  forceDial = false): Future[void] {.public.} =
  ## Connects to a peer without opening a stream to it

  s.dialer.connect(peerId, addrs, forceDial)

method connect*(
  s: Switch,
  address: MultiAddress,
  allowUnknownPeerId = false): Future[PeerId] =
  ## Connects to a peer and retrieve its PeerId
  ##
  ## If the P2P part is missing from the MA and `allowUnknownPeerId` is set
  ## to true, this will discover the PeerId while connecting. This exposes
  ## you to MiTM attacks, so it shouldn't be used without care!

  s.dialer.connect(address, allowUnknownPeerId)

method dial*(
  s: Switch,
  peerId: PeerId,
  protos: seq[string]): Future[Connection] {.public.} =
  ## Open a stream to a connected peer with the specified `protos`

  s.dialer.dial(peerId, protos)

proc dial*(s: Switch,
           peerId: PeerId,
           proto: string): Future[Connection] {.public.} =
  ## Open a stream to a connected peer with the specified `proto`

  dial(s, peerId, @[proto])

method dial*(
  s: Switch,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  protos: seq[string],
  forceDial = false): Future[Connection] {.public.} =
  ## Connected to a peer and open a stream
  ## with the specified `protos`

  s.dialer.dial(peerId, addrs, protos, forceDial)

proc dial*(
  s: Switch,
  peerId: PeerId,
  addrs: seq[MultiAddress],
  proto: string): Future[Connection] {.public.} =
  ## Connected to a peer and open a stream
  ## with the specified `proto`

  dial(s, peerId, addrs, @[proto])

proc mount*[T: LPProtocol](s: Switch, proto: T, matcher: Matcher = nil)
  {.gcsafe, raises: [Defect, LPError], public.} =
  ## mount a protocol to the switch

  if isNil(proto.handler):
    raise newException(LPError,
      "Protocol has to define a handle method or proc")

  if proto.codec.len == 0:
    raise newException(LPError,
      "Protocol has to define a codec string")

  if s.started and not proto.started:
    raise newException(LPError, "Protocol not started")

  s.ms.addHandler(proto.codecs, proto, matcher)
  s.peerInfo.protocols.add(proto.codec)

proc upgradeMonitor(conn: Connection, upgrades: AsyncSemaphore) {.async.} =
  ## monitor connection for upgrades
  ##
  try:
    # Since we don't control the flow of the
    # upgrade, this timeout guarantees that a
    # "hanged" remote doesn't hold the upgrade
    # forever
    await conn.onUpgrade.wait(30.seconds) # wait for connection to be upgraded
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

  let upgrades = newAsyncSemaphore(ConcurrentUpgrades)
  while transport.running:
    var conn: Connection
    try:
      debug "About to accept incoming connection"
      # remember to always release the slot when
      # the upgrade succeeds or fails, this is
      # currently done by the `upgradeMonitor`
      await upgrades.acquire()    # first wait for an upgrade slot to become available
      let slot = await s.connManager.getIncomingSlot()
      conn =
        try:
          await transport.accept()
        except CatchableError as exc:
          slot.release()
          raise exc
      slot.trackConnection(conn)
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

      # set the direction of this bottom level transport
      # in order to be able to consume this information in gossipsub if required
      # gossipsub gives priority to connections we make
      conn.transportDir = Direction.In

      debug "Accepted an incoming connection", conn
      asyncSpawn upgradeMonitor(conn, upgrades)
      asyncSpawn transport.upgradeIncoming(conn)
    except CancelledError as exc:
      trace "releasing semaphore on cancellation"
      upgrades.release() # always release the slot
    except CatchableError as exc:
      debug "Exception in accept loop, exiting", exc = exc.msg
      upgrades.release() # always release the slot
      if not isNil(conn):
        await conn.close()
      return

proc stop*(s: Switch) {.async, public.} =
  ## Stop listening on every transport, and
  ## close every active connections

  trace "Stopping switch"

  s.started = false

  for service in s.services:
    discard await service.stop(s)

  # close and cleanup all connections
  await s.connManager.close()

  for transp in s.transports:
    try:
      await transp.stop()
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

  for service in s.services:
    discard await service.stop(s)

  await s.ms.stop()

  trace "Switch stopped"

proc start*(s: Switch) {.async, gcsafe, public.} =
  ## Start listening on every transport

  if s.started:
    warn "Switch has already been started"
    return

  trace "starting switch for peer", peerInfo = s.peerInfo
  var startFuts: seq[Future[void]]
  for t in s.transports:
    let addrs = s.peerInfo.listenAddrs.filterIt(
      t.handles(it)
    )

    s.peerInfo.listenAddrs.keepItIf(
      it notin addrs
    )

    if addrs.len > 0 or t.running:
      startFuts.add(t.start(addrs))

  await allFutures(startFuts)

  for fut in startFuts:
    if fut.failed:
      await s.stop()
      raise fut.error

  for t in s.transports: # for each transport
    if t.addrs.len > 0 or t.running:
      s.acceptFuts.add(s.accept(t))
      s.peerInfo.listenAddrs &= t.addrs

  await s.peerInfo.update()

  await s.ms.start()

  for service in s.services:
    discard await service.setup(s)

  s.started = true

  debug "Started libp2p node", peer = s.peerInfo

proc newSwitch*(peerInfo: PeerInfo,
                transports: seq[Transport],
                identity: Identify,
                secureManagers: openArray[Secure] = [],
                connManager: ConnManager,
                ms: MultistreamSelect,
                nameResolver: NameResolver = nil,
                peerStore = PeerStore.new(),
                services = newSeq[Service]()): Switch
                {.raises: [Defect, LPError], public.} =
  if secureManagers.len == 0:
    raise newException(LPError, "Provide at least one secure manager")

  let switch = Switch(
    peerInfo: peerInfo,
    ms: ms,
    transports: transports,
    connManager: connManager,
    peerStore: peerStore,
    dialer: Dialer.new(peerInfo.peerId, connManager, transports, ms, nameResolver),
    nameResolver: nameResolver,
    services: services)

  switch.connManager.peerStore = peerStore
  switch.mount(identity)

  return switch

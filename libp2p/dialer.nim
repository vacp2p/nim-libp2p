# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, tables]

import pkg/[chronos, chronicles, metrics, results]

import
  dial,
  peerid,
  peerinfo,
  peerstore,
  peeraddrpolicy,
  multicodec,
  muxers/muxer,
  multistream,
  connmanager,
  stream/connection,
  transports/transport,
  nameresolving/nameresolver,
  upgrademngrs/upgrade,
  utils/future,
  errors

export dial, errors, results

logScope:
  topics = "libp2p dialer"

declareCounter(libp2p_total_dial_attempts, "total attempted dials")
declareCounter(libp2p_successful_dials, "dialed successful peers")
declareCounter(libp2p_failed_dials, "failed dials")
declarePublicHistogram libp2p_dial_duration_ms,
  "dial and connection upgrade duration in milliseconds",
  ["result"],
  buckets =
    [10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0, 5000.0, 10000.0, 30000.0]

const DefaultDialerTimeout* = 30.seconds
  ## Budget for reaching one peer. Every address it advertises shares it, and
  ## identify gets the same budget again once a connection stands. The transport
  ## dial and the upgrade have no bound of their own, so without this a remote
  ## that goes quiet mid-handshake holds the peer's dial lock forever.

type
  DialLock = ref object
    lock: AsyncLock
    users: int ## dials holding or waiting for `lock`

  Dialer* = ref object of Dial
    localPeerId*: PeerId
    connManager: ConnManager
    dialLocks: Table[PeerId, DialLock]
    dialTimeout: Duration
    transports: seq[Transport]
    peerStore: PeerStore
    nameResolver: NameResolver
    ms: MultistreamSelect
    ongoingReleaseOnClose: seq[Future[void].Raising([])]

proc dialAndUpgrade*(
    self: Dialer,
    peerId: Opt[PeerId],
    hostname: string,
    addrs: MultiAddress,
    dir = Direction.Out,
    deadline = Moment.now() + self.dialTimeout,
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Dial one resolved transport address and upgrade it to a muxer.
  ## Returns nil when no transport can establish an upgraded connection.

  for transport in self.transports: # for each transport
    if transport.handles(addrs): # check if it can dial it
      let dialStarted = Moment.now()
      trace "Dialing address", addrs, peerId, hostname
      let dialed =
        try:
          libp2p_total_dial_attempts.inc()
          await transport.dial(hostname, addrs, peerId, dir).wait(deadline.timeLeft())
        except CancelledError as e:
          trace "Dialing canceled", description = e.msg, peerId
          raise e
        except CatchableError as e:
          debug "Dialing failed",
            description = e.msg, peerId = peerId, address = addrs, hostname
          libp2p_failed_dials.inc()
          libp2p_dial_duration_ms.observe(
            (Moment.now() - dialStarted).milliseconds, labelValues = ["failed"]
          )
          return nil # Try the next address

      libp2p_successful_dials.inc()

      let mux =
        try:
          # This is for the very specific case of a simultaneous dial during DCUtR. In this case, both sides will have
          # an Outbound direction at the transport level. Therefore we update the DCUtR initiator transport direction to Inbound.
          # The if below is more general and might handle other use cases in the future.
          if dialed.dir != dir:
            dialed.dir = dir
          await transport.upgrade(dialed, peerId).wait(deadline.timeLeft())
        except CancelledError as e:
          await dialed.close()
          raise e
        except CatchableError as e:
          # If we failed to establish the connection through one transport,
          # we won't succeeded through another - no use in trying again
          await dialed.close()
          debug "Connection upgrade failed",
            description = e.msg, peerId, address = addrs, hostname
          if dialed.dir == Direction.Out:
            libp2p_failed_upgrades_outgoing.inc()
          else:
            libp2p_failed_upgrades_incoming.inc()
          libp2p_dial_duration_ms.observe(
            (Moment.now() - dialStarted).milliseconds, labelValues = ["upgrade_failed"]
          )

          # Try other address
          return nil

      doAssert not isNil(mux), "connection died after upgrade " & $dialed.dir
      debug "Dial successful", peerId = mux.connection.peerId
      libp2p_dial_duration_ms.observe(
        (Moment.now() - dialStarted).milliseconds, labelValues = ["success"]
      )
      let filtered = self.peerStore.addressPolicy.filterAddrs(@[addrs])
      if filtered.len > 0:
        self.peerStore[AddressBook].markConnected(mux.connection.peerId, filtered[0])
      return mux
  return nil

proc expandDnsAddr(
    self: Dialer, peerId: Opt[PeerId], address: MultiAddress
): Future[seq[(MultiAddress, Opt[PeerId])]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError, LPError])
.} =
  if not DNS.matchPartial(address):
    return @[(address, peerId)]
  if isNil(self.nameResolver):
    info "Can't resolve DNSADDR without NameResolver", ma = address
    return @[]

  trace "Start trying to resolve addresses"
  let
    toResolve =
      if peerId.isSome:
        try:
          address & MultiAddress.init(multiCodec("p2p"), peerId.tryGet()).tryGet()
        except ResultError[void]:
          raiseAssert "checked with if"
      else:
        address
    resolved = await self.nameResolver.resolveDnsAddr(toResolve)

  debug "resolved addresses",
    originalAddresses = toResolve, resolvedAddresses = resolved

  var addrs: seq[(MultiAddress, Opt[PeerId])]
  for resolvedAddress in resolved:
    let lastPart = resolvedAddress[^1].tryGet()
    if lastPart.protoCode == Result[MultiCodec, string].ok(multiCodec("p2p")):
      var peerIdBytes: seq[byte]
      try:
        peerIdBytes = lastPart.protoArgument().tryGet()
      except ResultError[string] as e:
        raiseAssert "expandDnsAddr failed in expandDnsAddr protoArgument: " & e.msg

      let addrPeerId = PeerId.init(peerIdBytes).tryGet()
      addrs.add((resolvedAddress[0 ..^ 2].tryGet(), Opt.some(addrPeerId)))
    else:
      addrs.add((resolvedAddress, peerId))
  addrs

proc normalizedDialAddrs(
    peerId: Opt[PeerId], addrs: seq[MultiAddress]
): seq[MultiAddress] =
  if peerId.isSome:
    addrs.mapIt(it.stripPeerId)
  else:
    addrs

proc dialAndUpgrade*(
    self: Dialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    dir = Direction.Out,
    deadline = Moment.now() + self.dialTimeout,
): Future[Muxer] {.
    async: (raises: [CancelledError, MaError, TransportAddressError, LPError])
.} =
  ## Dial address candidates, resolving DNS addresses when configured.
  ## Returns the first upgraded muxer, or nil when no address succeeds.
  ## Every candidate shares `deadline`: a peer names as many addresses as it
  ## likes, and each one it stalls on would otherwise cost a full timeout.

  let dialAddrs = normalizedDialAddrs(peerId, addrs)
  debug "Dialing peer", peerId = peerId, addrs = dialAddrs

  for rawAddress in dialAddrs:
    if deadline.timeLeft().isZero():
      debug "Out of time for the remaining addresses", peerId, addrs = dialAddrs
      return nil
    # resolve potential dnsaddr
    let addresses = await self.expandDnsAddr(peerId, rawAddress)
    for (expandedAddress, addrPeerId) in addresses:
      # DNS resolution
      let
        hostname = expandedAddress.getHostname()
        resolvedAddresses =
          if isNil(self.nameResolver):
            @[expandedAddress]
          else:
            await self.nameResolver.resolveMAddress(expandedAddress)

      debug "Expanded address and hostname",
        expandedAddress = expandedAddress,
        hostname = hostname,
        resolvedAddresses = resolvedAddresses

      for resolvedAddress in resolvedAddresses:
        let mux = await self.dialAndUpgrade(
          addrPeerId, hostname, resolvedAddress, dir, deadline
        )
        if not isNil(mux):
          return mux

proc tryReusingConnection(self: Dialer, peerId: PeerId): Opt[Muxer] =
  let muxer = self.connManager.selectMuxer(peerId)
  if muxer == nil:
    return Opt.none(Muxer)

  trace "Reusing existing connection", muxer, direction = $muxer.connection.dir
  return Opt.some(muxer)

proc release(dialLock: DialLock) {.raises: [].} =
  try:
    dialLock.lock.release()
  except AsyncLockError as e:
    raiseAssert "dial lock released without acquire: " & e.msg

proc dropUser(self: Dialer, peerId: PeerId, dialLock: DialLock) {.raises: [].} =
  ## Drop the entry once nobody holds or waits for it, so the table stays bounded
  ## by the number of concurrent dials instead of by every peer ever dialed.
  dialLock.users.dec()
  if dialLock.users == 0 and self.dialLocks.getOrDefault(peerId) == dialLock:
    self.dialLocks.del(peerId)

proc acquireDialLock(
    self: Dialer, peerId: PeerId
): Future[DialLock] {.async: (raises: [CancelledError]).} =
  let dialLock = self.dialLocks.mgetOrPut(peerId, DialLock(lock: newAsyncLock()))
  dialLock.users.inc()
  # Cancellation can land at the instant chronos hands the lock over, which
  # leaves it held with no owner and stalls every later dial to this peer.
  let acquireFut = dialLock.lock.acquire()
  try:
    await acquireFut
  except CancelledError as e:
    if acquireFut.completed():
      dialLock.release()
    self.dropUser(peerId, dialLock)
    raise e
  dialLock

proc finishUpgrade(
    self: Dialer, muxed: Muxer, dir: Direction
) {.async: (raises: [DialFailedError, CancelledError]).} =
  ## Store the muxer, learn who is on the other end, and announce the peer.
  try:
    await self.connManager.storeMuxer(muxed)
    # Its own budget, not the dial's leftovers: the connection stands at this
    # point, and a remote that never answers identify would otherwise hold the
    # peer's dial lock for as long as that connection lives.
    await self.peerStore.identify(muxed, dir).wait(self.dialTimeout)
    await self.connManager.triggerPeerEvents(
      muxed.connection.peerId,
      PeerEvent(kind: PeerEventKind.Identified, initiator: true),
    )
  except CancelledError as e:
    await muxed.close()
    raise e
  except CatchableError as e:
    trace "Failed to finish outgoing upgrade", description = e.msg
    await muxed.close()
    raise newException(
      DialFailedError, "failed finishUpgrade in establishConnection: " & e.msg, e
    )

proc establishConnection(
    self: Dialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    forceDial: bool,
    reuseConnection: bool,
    dir: Direction,
): Future[Muxer] {.async: (raises: [DialFailedError, CancelledError]).} =
  if reuseConnection:
    peerId.withValue(peerId):
      self.tryReusingConnection(peerId).withValue(mux):
        return mux

  let slot =
    try:
      self.connManager.getOutgoingSlot(forceDial)
    except TooManyConnectionsError as e:
      raise newException(
        DialFailedError, "failed getOutgoingSlot in establishConnection: " & e.msg, e
      )

  let dialAddrs = normalizedDialAddrs(peerId, addrs)
  let muxed =
    try:
      await self.dialAndUpgrade(peerId, dialAddrs, dir, Moment.now() + self.dialTimeout)
    except CancelledError as e:
      slot.release()
      raise e
    except CatchableError as e:
      slot.release()
      raise newException(
        DialFailedError, "failed dialAndUpgrade in establishConnection: " & e.msg, e
      )
  if isNil(muxed): # None of the addresses connected
    slot.release()
    raise newException(
      DialFailedError,
      "Unable to establish outgoing link in establishConnection: peer_id=" &
        shortLog(peerId) & " addrs=" & $dialAddrs,
    )

  slot.trackMuxer(muxed)
  await self.finishUpgrade(muxed, dir)
  muxed

proc internalConnect(
    self: Dialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    forceDial: bool,
    reuseConnection = true,
    dir = Direction.Out,
): Future[Muxer] {.async: (raises: [DialFailedError, CancelledError]).} =
  if Opt.some(self.localPeerId) == peerId:
    raise newException(DialFailedError, "internalConnect can't dial self!")

  # A dial without a peer id has no connection to reuse and no identity to
  # serialize on. Sharing one lock for all of them would make an unreachable
  # address block every other address dial.
  let pid = peerId.valueOr:
    return
      await self.establishConnection(peerId, addrs, forceDial, reuseConnection, dir)

  # Ensure there's only one in-flight attempt per peer
  let dialLock = await self.acquireDialLock(pid)
  defer:
    dialLock.release()
    self.dropUser(pid, dialLock)

  await self.establishConnection(peerId, addrs, forceDial, reuseConnection, dir)

method connect*(
    self: Dialer,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    forceDial = false,
    reuseConnection = true,
    dir = Direction.Out,
) {.async: (raises: [DialFailedError, CancelledError]).} =
  ## connect remote peer without negotiating
  ## a protocol
  ##

  if self.connManager.connCount(peerId) > 0 and reuseConnection:
    return

  discard
    await self.internalConnect(Opt.some(peerId), addrs, forceDial, reuseConnection, dir)

method connect*(
    self: Dialer, address: MultiAddress, allowUnknownPeerId = false
): Future[PeerId] {.async: (raises: [DialFailedError, CancelledError]).} =
  ## Connects to a peer and retrieve its PeerId

  parseFullAddress(address).toOpt().withValue(fullAddress):
    return (
      await self.internalConnect(Opt.some(fullAddress[0]), @[fullAddress[1]], false)
    ).connection.peerId

  if allowUnknownPeerId == false:
    raise newException(
      DialFailedError, "Address without PeerID and unknown peer id disabled in connect"
    )

  return
    (await self.internalConnect(Opt.none(PeerId), @[address], false)).connection.peerId

proc negotiateStream*(
    self: Dialer, stream: Stream, protos: seq[string]
): Future[Stream] {.async: (raises: [CancelledError, LPError]).} =
  ## Negotiate one of `protos` over an open stream.
  ## Raises DialFailedError when negotiation selects no supported protocol or
  ## the selected protocol's outgoing stream budget is exhausted.

  trace "Negotiating stream", stream, protos
  let selected = await MultistreamSelect.select(stream, protos)
  if not protos.contains(selected):
    await stream.reset()
    raise newException(
      DialFailedError,
      "Unable to select sub-protocol. Selected: " & $selected & ". Available: " & $protos,
    )

  self.ms.lookupProtocol(selected).withValue(protocol):
    if not protocol.reserveOutgoing(stream.peerId):
      await stream.reset()
      raise newException(
        DialFailedError, "Outbound stream budget exceeded for protocol: " & selected
      )

    proc releaseOnClose() {.async: (raises: []).} =
      await noCancel stream.join()
      protocol.releaseOutgoing(stream.peerId)

    let fut = releaseOnClose()
    self.ongoingReleaseOnClose.add(fut)
    fut.addCallback proc(udata: pointer) =
      let idx = self.ongoingReleaseOnClose.find(fut)
      if idx >= 0:
        self.ongoingReleaseOnClose.del(idx)

  return stream

proc tryDial*(
    self: Dialer, peerId: PeerId, addrs: seq[MultiAddress]
): Future[Opt[MultiAddress]] {.async: (raises: [DialFailedError, CancelledError]).} =
  ## Create a protocol stream in order to check
  ## if a connection is possible.
  ## Doesn't use the Connection Manager to save it.
  ## Returns the observed address when the probe succeeds.
  ##

  trace "Check if it can dial", peerId, addrs
  try:
    let mux = await self.dialAndUpgrade(Opt.some(peerId), addrs)
    if mux.isNil():
      raise newException(DialFailedError, "No valid multiaddress in tryDial")
    await mux.close()
    return mux.connection.observedAddr
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(DialFailedError, "tryDial failed: " & exc.msg, exc)

method dial*(
    self: Dialer, peerId: PeerId, protos: seq[string]
): Future[Stream] {.async: (raises: [DialFailedError, CancelledError]).} =
  ## create a protocol stream over an
  ## existing connection
  ##

  trace "Dialing (existing)", peerId, protos

  try:
    let stream = await self.connManager.getStream(peerId)
    if stream.isNil:
      raise newException(
        DialFailedError,
        "Couldn't get muxed stream in dial for peer_id: " & shortLog(peerId),
      )
    return await self.negotiateStream(stream, protos)
  except CancelledError as exc:
    trace "Dial canceled", description = exc.msg
    raise exc
  except CatchableError as exc:
    trace "Error dialing", description = exc.msg
    raise newException(DialFailedError, "failed dial existing: " & exc.msg)

method dial*(
    self: Dialer,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    protos: seq[string],
    forceDial = false,
): Future[Stream] {.async: (raises: [DialFailedError, CancelledError]).} =
  ## create a protocol stream and establish
  ## a connection if one doesn't exist already
  ##

  var
    conn: Muxer
    stream: Stream

  let dialAddrs = normalizedDialAddrs(Opt.some(peerId), addrs)

  # `conn` belongs to the connection manager and carries other protocols' streams.
  proc cleanup() {.async: (raises: []).} =
    if not (isNil(stream)):
      await stream.reset()

  try:
    trace "Dialing (new)", peerId, protos
    conn = await self.internalConnect(Opt.some(peerId), dialAddrs, forceDial)
    trace "Opening stream", conn
    stream = await self.connManager.getStream(conn)

    if isNil(stream):
      raise newException(
        DialFailedError,
        "Couldn't get muxed stream in new dial for remote_peer_id: " & shortLog(peerId),
      )

    return await self.negotiateStream(stream, protos)
  except CancelledError as exc:
    trace "Dial canceled", conn, description = exc.msg
    await cleanup()
    raise exc
  except CatchableError as exc:
    debug "Error dialing",
      conn, peerId, protos, addrs = dialAddrs, description = exc.msg
    await cleanup()
    raise newException(
      DialFailedError,
      "failed new dial: peer_id=" & shortLog(peerId) & " protos=" & $protos & " addrs=" &
        $dialAddrs & ": " & exc.msg,
      exc,
    )

method addTransport*(self: Dialer, t: Transport) {.raises: [].} =
  self.transports &= t

proc new*(
    T: type Dialer,
    localPeerId: PeerId,
    connManager: ConnManager,
    peerStore: PeerStore,
    transports: seq[Transport],
    ms: MultistreamSelect,
    nameResolver: NameResolver = nil,
    dialTimeout = DefaultDialerTimeout,
): Dialer =
  T(
    localPeerId: localPeerId,
    connManager: connManager,
    transports: transports,
    peerStore: peerStore,
    nameResolver: nameResolver,
    ms: ms,
    dialTimeout: dialTimeout,
  )

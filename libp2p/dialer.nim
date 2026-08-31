# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, tables]

import pkg/[chronos, chronicles, metrics, results]

import
  dial,
  dialcandidate,
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
  utils/collections,
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

const MaxDialCandidates* = 32
  ## A peer names as many addresses as it likes, and each dnsaddr fans out further.

const MaxExpandedAddresses = MaxDialCandidates * 8
  ## Ceiling on what one peer's dnsaddr chain holds in flight before the filter.

const DefaultDialerTimeout* = 30.seconds
  ## Budget for reaching one peer. Every address it advertises shares it, and
  ## identify gets the same budget again once a connection stands. The transport
  ## dial and the upgrade have no bound of their own, so without this a remote
  ## that goes quiet mid-handshake holds the peer's dial lock forever.

type
  DialAttempt = Future[Muxer].Raising([CancelledError])

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
    dialRanking: bool ## overlap the name lookups with the dials
    ongoingReleaseOnClose: seq[Future[void].Raising([])]

proc transportFor(self: Dialer, address: MultiAddress): Opt[Transport] =
  for transport in self.transports:
    if transport.handles(address):
      return Opt.some(transport)
  Opt.none(Transport)

proc dialAndUpgrade*(
    self: Dialer,
    peerId: Opt[PeerId],
    hostname: string,
    addrs: MultiAddress,
    dir = Direction.Out,
    deadline = Moment.now() + self.dialTimeout,
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Dial one resolved address, below candidate selection. Nil when no transport connects.

  let transport = self.transportFor(addrs).valueOr:
    return nil

  let dialStarted = Moment.now()
  trace "Dialing address", addrs, peerId, hostname
  let dialed =
    try:
      libp2p_total_dial_attempts.inc()
      transport.dial(hostname, addrs, peerId, dir).awaitWithDeadline(deadline)
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
      # A DCUtR simultaneous dial leaves both sides Outbound, so the initiator takes `dir`.
      dialed.dir = dir
      transport.upgrade(dialed, peerId).awaitWithDeadline(deadline)
    except CancelledError as e:
      await dialed.close()
      raise e
    except CatchableError as e:
      # Another transport for the same address fails the same way, so give this one up.
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

  mux

proc expandDnsAddr(
    self: Dialer, peerId: Opt[PeerId], address: MultiAddress, deadline: Moment
): Future[seq[(MultiAddress, Opt[PeerId])]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError, LPError])
.} =
  if not DNS.matchPartial(address):
    return @[(address, peerId)]
  if isNil(self.nameResolver):
    info "Can't resolve DNSADDR without NameResolver", ma = address
    return @[]

  trace "Start trying to resolve addresses"
  let toResolve =
    if peerId.isSome:
      try:
        address & MultiAddress.init(multiCodec("p2p"), peerId.tryGet()).tryGet()
      except ResultError[void]:
        raiseAssert "checked with if"
    else:
      address
  # A dnsaddr record points at more dnsaddr records, and each lookup can take
  # seconds, so the chain answers to the dial deadline like the dial itself.
  let resolved =
    try:
      self.nameResolver.resolveDnsAddr(toResolve).awaitWithDeadline(deadline)
    except AsyncTimeoutError:
      debug "Out of time resolving dnsaddr", ma = toResolve
      return @[]

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

proc resolveWithDeadline(
    self: Dialer, address: MultiAddress, deadline: Moment
): Future[seq[MultiAddress]] {.
    async: (raises: [CancelledError, MaError, TransportAddressError])
.} =
  ## Empty when the resolver has no answer left in the dial's budget.
  if isNil(self.nameResolver):
    return @[address]
  try:
    self.nameResolver.resolveMAddress(address).awaitWithDeadline(deadline)
  except AsyncTimeoutError:
    debug "Out of time resolving address", ma = address
    @[]

proc tryExpandDnsAddr(
    self: Dialer, peerId: Opt[PeerId], address: MultiAddress, deadline: Moment
): Future[seq[(MultiAddress, Opt[PeerId])]] {.async: (raises: [CancelledError]).} =
  ## Empty when the record is unusable, so one bad record cannot fail the dial.
  try:
    await self.expandDnsAddr(peerId, address, deadline)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    debug "Skipping the address, dnsaddr expansion failed",
      peerId, ma = address, description = e.msg
    @[]

proc tryResolve(
    self: Dialer, address: MultiAddress, deadline: Moment
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  ## Empty when the name does not resolve, so one bad name cannot fail the dial.
  try:
    await self.resolveWithDeadline(address, deadline)
  except CancelledError as e:
    raise e
  except CatchableError as e:
    debug "Skipping the address, name resolution failed",
      ma = address, description = e.msg
    @[]

proc normalizedDialAddrs(
    peerId: Opt[PeerId], addrs: seq[MultiAddress]
): seq[MultiAddress] =
  if peerId.isSome:
    addrs.mapIt(it.stripPeerId)
  else:
    addrs

type DialBudget = ref object
  ## One cap and one seen set shared by every holder of the same dial.
  left: int
  seen: HashSet[string]
  exhausted: AsyncEvent

proc newBudget(limit: int): DialBudget =
  let budget = DialBudget(left: max(limit, 0), exhausted: newAsyncEvent())
  if budget.left == 0:
    budget.exhausted.fire()
  budget

proc take(budget: DialBudget, candidates: seq[DialCandidate]): seq[DialCandidate] =
  var fresh: seq[DialCandidate]
  for candidate in candidates:
    if not budget.seen.containsOrIncl(candidate.key()):
      fresh.add(candidate)

  if fresh.len > budget.left:
    debug "Dropping the addresses over the candidate limit", limit = budget.left

  let taken = fresh.take(budget.left)
  budget.left -= taken.len
  if budget.left == 0:
    budget.exhausted.fire()
  taken

proc awaitLookup(
    budget: DialBudget, lookup: Future[seq[DialCandidate]].Raising([CancelledError])
): Future[seq[DialCandidate]] {.async: (raises: [CancelledError]).} =
  ## Empty once the budget leaves no room for the answer, so a stalling name ends here.

  let exhausted = budget.exhausted.wait()
  defer:
    await noCancel allFutures(exhausted.cancelAndWait(), lookup.cancelAndWait())

  discard await race(lookup, exhausted)
  if lookup.completed():
    return lookup.value()

  debug "Giving up the lookup, the dial candidate limit is reached"
  @[]

proc expandCandidate(
    self: Dialer, candidate: DialCandidate, deadline: Moment
): Future[seq[DialCandidate]] {.async: (raises: [CancelledError]).} =
  ## The addresses one dnsaddr record stands for, each of them still unresolved.

  var expanded: seq[DialCandidate]
  for (address, addrPeerId) in await self.tryExpandDnsAddr(
    candidate.peerId, candidate.address, deadline
  ):
    expanded.add(
      DialCandidate(
        address: address, hostname: address.getHostname(), peerId: addrPeerId
      )
    )

  expanded

proc resolveCandidate(
    self: Dialer, candidate: DialCandidate, deadline: Moment
): Future[seq[DialCandidate]] {.async: (raises: [CancelledError]).} =
  ## The wire addresses one name resolves to, minus the ones no transport handles.

  let resolved = await self.tryResolve(candidate.address, deadline)

  debug "Resolved address",
    expandedAddress = candidate.address,
    hostname = candidate.hostname,
    resolvedAddresses = resolved

  var candidates: seq[DialCandidate]
  for address in resolved:
    if self.transportFor(address).isNone():
      debug "Skipping the address, no transport handles it",
        peerId = candidate.peerId, ma = address
      continue

    candidates.add(
      DialCandidate(
        address: address, hostname: candidate.hostname, peerId: candidate.peerId
      )
    )

  candidates

proc resolveName(
    self: Dialer, candidate: DialCandidate, budget: DialBudget, deadline: Moment
): Future[seq[DialCandidate]] {.async: (raises: [CancelledError]).} =
  ## Every wire address one advertised name stands for, dnsaddr chain included.

  let expanded = budget.take(await self.expandCandidate(candidate, deadline))
  concat(await collectCompleted(expanded.mapIt(self.resolveCandidate(it, deadline))))

proc directCandidates(
    self: Dialer, peerId: Opt[PeerId], addrs: seq[MultiAddress]
): seq[DialCandidate] =
  ## The advertised addresses a transport can dial with no lookup at all.

  var candidates: seq[DialCandidate]
  for address in addrs:
    if DNS.matchPartial(address):
      continue
    if self.transportFor(address).isNone():
      debug "Skipping the address, no transport handles it", peerId, ma = address
      continue

    # `wstransport` sends this as the Host header, so a wire address needs it too.
    candidates.add(
      DialCandidate(address: address, hostname: address.getHostname(), peerId: peerId)
    )

  candidates

proc dnsCandidates(peerId: Opt[PeerId], addrs: seq[MultiAddress]): seq[DialCandidate] =
  ## The advertised addresses that need a lookup before anything can dial them.

  addrs.filterIt(DNS.matchPartial(it)).mapIt(DialCandidate(address: it, peerId: peerId))

proc dialInOrder(
    self: Dialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    dir: Direction,
    deadline: Moment,
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Resolve one address at a time and dial it right away.

  for rawAddress in addrs:
    if deadline.timeLeft().isZero():
      debug "Out of time for the remaining addresses", peerId, addrs
      return nil

    let advertised = DialCandidate(address: rawAddress, peerId: peerId)
    for expanded in await self.expandCandidate(advertised, deadline):
      for candidate in await self.resolveCandidate(expanded, deadline):
        let mux = await self.dialAndUpgrade(
          candidate.peerId, candidate.hostname, candidate.address, dir, deadline
        )
        if not isNil(mux):
          return mux

proc dropLosers(attempts: seq[DialAttempt]) {.async: (raises: []).} =
  ## Give up every attempt that did not win, and close a muxer that landed anyway.

  await noCancel attempts.cancelAndWait()
  for attempt in attempts:
    if attempt.completed():
      let mux = attempt.value()
      if not isNil(mux):
        await mux.close()

proc firstConnected(
    attempts: seq[DialAttempt]
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## The first attempt that connects. Nil when none of them does.

  var pending = attempts
  defer:
    await dropLosers(pending)

  while pending.len > 0:
    let done =
      try:
        await one(pending)
      except ValueError as e:
        raiseAssert "one() over a non-empty seq: " & e.msg
    pending.del(pending.find(done))

    if not done.completed():
      continue

    let mux = done.value()
    if not isNil(mux):
      return mux

proc dialAll(
    self: Dialer, candidates: seq[DialCandidate], dir: Direction, deadline: Moment
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Dial every candidate at once. Nil when none of them connects.

  await firstConnected(
    candidates.mapIt(
      self.dialAndUpgrade(it.peerId, it.hostname, it.address, dir, deadline)
    )
  )

proc dialResolved(
    self: Dialer,
    lookup: Future[seq[DialCandidate]].Raising([CancelledError]),
    budget: DialBudget,
    dir: Direction,
    deadline: Moment,
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Dial one name's addresses the moment that name answers.

  await self.dialAll(budget.take(await budget.awaitLookup(lookup)), dir, deadline)

proc dialRanked(
    self: Dialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    dir: Direction,
    deadline: Moment,
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Dial the wire addresses at once, and each name's as soon as it resolves.

  let
    dialable = newBudget(MaxDialCandidates)
    names = newBudget(MaxDialCandidates)
    unresolved = newBudget(MaxExpandedAddresses)
    direct = dialable.take(self.directCandidates(peerId, addrs))
    lookups = names.take(dnsCandidates(peerId, addrs)).mapIt(
        self.resolveName(it, unresolved, deadline)
      )

  await firstConnected(
    @[self.dialAll(direct, dir, deadline)] &
      lookups.mapIt(self.dialResolved(it, dialable, dir, deadline))
  )

proc dialAndUpgrade*(
    self: Dialer,
    peerId: Opt[PeerId],
    addrs: seq[MultiAddress],
    dir = Direction.Out,
    deadline = Moment.now() + self.dialTimeout,
): Future[Muxer] {.async: (raises: [CancelledError]).} =
  ## Dial the addresses, sharing one `deadline`. Nil when all of them fail.

  let dialAddrs = normalizedDialAddrs(peerId, addrs)
  debug "Dialing peer", peerId = peerId, addrs = dialAddrs

  if self.dialRanking:
    await self.dialRanked(peerId, dialAddrs, dir, deadline)
  else:
    await self.dialInOrder(peerId, dialAddrs, dir, deadline)

proc tryReusingConnection(self: Dialer, peerId: PeerId): Opt[Muxer] =
  let muxer = self.connManager.selectMuxer(peerId)
  if muxer == nil:
    return Opt.none(Muxer)

  trace "Reusing existing connection", muxer, direction = $muxer.connection.dir
  return Opt.some(muxer)

proc dropUser(self: Dialer, peerId: PeerId, dialLock: DialLock) {.raises: [].} =
  ## Drop the entry once nobody holds or waits for it, so the table stays bounded
  ## by the number of concurrent dials instead of by every peer ever dialed.
  dialLock.users.dec()
  if dialLock.users == 0 and self.dialLocks.getOrDefault(peerId) == dialLock:
    self.dialLocks.del(peerId)

proc releaseDialLock(self: Dialer, peerId: PeerId, dialLock: DialLock) {.raises: [].} =
  try:
    dialLock.lock.release()
  except AsyncLockError as e:
    raiseAssert "dial lock released without acquire: " & e.msg
  self.dropUser(peerId, dialLock)

proc acquireDialLock(
    self: Dialer, peerId: PeerId
): Future[DialLock] {.async: (raises: [CancelledError]).} =
  let dialLock = self.dialLocks.mgetOrPut(peerId, DialLock(lock: newAsyncLock()))
  dialLock.users.inc()
  try:
    await dialLock.lock.acquire()
  except CancelledError as e:
    # The lock is not ours: chronos leaves the waiter in the queue and skips it
    # on the next handover.
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
    self.releaseDialLock(pid, dialLock)

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
    dialRanking = false,
): Dialer {.raises: [].} =
  T(
    localPeerId: localPeerId,
    connManager: connManager,
    transports: transports,
    peerStore: peerStore,
    nameResolver: nameResolver,
    ms: ms,
    dialTimeout: dialTimeout,
    dialRanking: dialRanking,
  )

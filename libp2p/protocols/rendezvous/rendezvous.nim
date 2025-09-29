# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import tables, sequtils, sugar, sets
import metrics except collect
import chronos, chronicles, bearssl/rand, stew/[byteutils, objects]
import
  ./protobuf,
  ../protocol,
  ../../protobuf/minprotobuf,
  ../../switch,
  ../../routing_record,
  ../../utils/heartbeat,
  ../../stream/connection,
  ../../utils/offsettedseq,
  ../../utils/semaphore,
  ../../discovery/discoverymngr

export chronicles

logScope:
  topics = "libp2p discovery rendezvous"

declareCounter(libp2p_rendezvous_register, "number of advertise requests")
declareCounter(libp2p_rendezvous_discover, "number of discovery requests")
declareGauge(libp2p_rendezvous_registered, "number of registered peers")
declareGauge(libp2p_rendezvous_namespaces, "number of registered namespaces")

const
  RendezVousCodec* = "/rendezvous/1.0.0"
  # Default minimum TTL per libp2p spec
  MinimumDuration* = 2.hours
  # Lower validation limit to accommodate Waku requirements
  MinimumAcceptedDuration = 1.minutes
  MaximumDuration = 72.hours
  MaximumMessageLen = 1 shl 22 # 4MB
  MinimumNamespaceLen = 1
  MaximumNamespaceLen = 255
  RegistrationLimitPerPeer* = 1000
  DiscoverLimit = 1000'u64
  SemaphoreDefaultSize = 5

type
  RendezVousError* = object of DiscoveryError
  RegisteredData = object
    expiration*: Moment
    peerId*: PeerId
    data*: Register

  RendezVous* = ref object of LPProtocol
    # Registered needs to be an offsetted sequence
    # because we need stable index for the cookies.
    registered*: OffsettedSeq[RegisteredData]
    # Namespaces is a table whose key is a salted namespace and
    # the value is the index sequence corresponding to this
    # namespace in the offsettedqueue.
    namespaces*: Table[string, seq[int]]
    rng: ref HmacDrbgContext
    salt: string
    expiredDT: Moment
    registerDeletionLoop: Future[void]
    #registerEvent: AsyncEvent # TODO: to raise during the heartbeat
    # + make the heartbeat sleep duration "smarter"
    sema: AsyncSemaphore
    peers: seq[PeerId]
    cookiesSaved*: Table[PeerId, Table[string, seq[byte]]]
    switch*: Switch
    minDuration: Duration
    maxDuration: Duration
    minTTL: uint64
    maxTTL: uint64

proc checkPeerRecord(spr: seq[byte], peerId: PeerId): Result[void, string] =
  if spr.len == 0:
    return err("Empty peer record")
  let signedEnv = ?SignedPeerRecord.decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()

proc sendRegisterResponse(
    conn: Connection, ttl: uint64
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = encode(
    Message(
      msgType: MessageType.RegisterResponse,
      registerResponse: Opt.some(RegisterResponse(status: Ok, ttl: Opt.some(ttl))),
    )
  )
  await conn.writeLp(msg.buffer)

proc sendRegisterResponseError(
    conn: Connection, status: ResponseStatus, text: string = ""
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = encode(
    Message(
      msgType: MessageType.RegisterResponse,
      registerResponse: Opt.some(RegisterResponse(status: status, text: Opt.some(text))),
    )
  )
  await conn.writeLp(msg.buffer)

proc sendDiscoverResponse(
    conn: Connection, s: seq[Register], cookie: Cookie
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = encode(
    Message(
      msgType: MessageType.DiscoverResponse,
      discoverResponse: Opt.some(
        DiscoverResponse(
          status: Ok, registrations: s, cookie: Opt.some(cookie.encode().buffer)
        )
      ),
    )
  )
  await conn.writeLp(msg.buffer)

proc sendDiscoverResponseError(
    conn: Connection, status: ResponseStatus, text: string = ""
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = encode(
    Message(
      msgType: MessageType.DiscoverResponse,
      discoverResponse: Opt.some(DiscoverResponse(status: status, text: Opt.some(text))),
    )
  )
  await conn.writeLp(msg.buffer)

proc countRegister(rdv: RendezVous, peerId: PeerId): int =
  for data in rdv.registered:
    if data.peerId == peerId:
      result.inc()

proc save(
    rdv: RendezVous, ns: string, peerId: PeerId, r: Register, update: bool = true
) =
  let nsSalted = ns & rdv.salt
  discard rdv.namespaces.hasKeyOrPut(nsSalted, newSeq[int]())
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == peerId:
        if update == false:
          return
        rdv.registered[index].expiration = rdv.expiredDT
    rdv.registered.add(
      RegisteredData(
        peerId: peerId,
        expiration: Moment.now() + r.ttl.get(rdv.minTTL).int64.seconds,
        data: r,
      )
    )
    rdv.namespaces[nsSalted].add(rdv.registered.high)
  #    rdv.registerEvent.fire()
  except KeyError as e:
    doAssert false, "Should have key: " & e.msg

proc register(rdv: RendezVous, conn: Connection, r: Register): Future[void] =
  trace "Received Register", peerId = conn.peerId, ns = r.ns
  libp2p_rendezvous_register.inc()
  if r.ns.len < MinimumNamespaceLen or r.ns.len > MaximumNamespaceLen:
    return conn.sendRegisterResponseError(InvalidNamespace)
  let ttl = r.ttl.get(rdv.minTTL)
  if ttl < rdv.minTTL or ttl > rdv.maxTTL:
    return conn.sendRegisterResponseError(InvalidTTL)
  let pr = checkPeerRecord(r.signedPeerRecord, conn.peerId)
  if pr.isErr():
    return conn.sendRegisterResponseError(InvalidSignedPeerRecord, pr.error())
  if rdv.countRegister(conn.peerId) >= RegistrationLimitPerPeer:
    return conn.sendRegisterResponseError(NotAuthorized, "Registration limit reached")
  rdv.save(r.ns, conn.peerId, r)
  libp2p_rendezvous_registered.inc()
  libp2p_rendezvous_namespaces.set(int64(rdv.namespaces.len))
  conn.sendRegisterResponse(ttl)

proc unregister*(rdv: RendezVous, conn: Connection, u: Unregister) =
  trace "Received Unregister", peerId = conn.peerId, ns = u.ns
  let nsSalted = u.ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == conn.peerId:
        rdv.registered[index].expiration = rdv.expiredDT
        libp2p_rendezvous_registered.dec()
  except KeyError:
    return

proc discover*(
    rdv: RendezVous, conn: Connection, d: Discover
) {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Received Discover", peerId = conn.peerId, ns = d.ns
  libp2p_rendezvous_discover.inc()
  if d.ns.isSome() and d.ns.get().len > MaximumNamespaceLen:
    await conn.sendDiscoverResponseError(InvalidNamespace)
    return
  var limit = min(DiscoverLimit, d.limit.get(DiscoverLimit))
  var cookie =
    if d.cookie.isSome():
      try:
        Cookie.decode(d.cookie.tryGet()).tryGet()
      except CatchableError:
        await conn.sendDiscoverResponseError(InvalidCookie)
        return
    else:
      # Start from the current lowest index (inclusive)
      Cookie(offset: rdv.registered.low().uint64)
  if d.ns.isSome() and cookie.ns.isSome() and cookie.ns.get() != d.ns.get():
    # Namespace changed: start from the beginning of that namespace
    cookie = Cookie(offset: rdv.registered.low().uint64)
  elif cookie.offset < rdv.registered.low().uint64:
    # Cookie behind available range: reset to current low
    cookie.offset = rdv.registered.low().uint64
  elif cookie.offset > (rdv.registered.high() + 1).uint64:
    # Cookie ahead of available range: reset to one past current high (empty page)
    cookie.offset = (rdv.registered.high() + 1).uint64
  let namespaces =
    if d.ns.isSome():
      try:
        rdv.namespaces[d.ns.get() & rdv.salt]
      except KeyError:
        await conn.sendDiscoverResponseError(InvalidNamespace)
        return
    else:
      toSeq(max(cookie.offset.int, rdv.registered.offset) .. rdv.registered.high())
  if namespaces.len() == 0:
    await conn.sendDiscoverResponse(@[], Cookie())
    return
  var nextOffset = cookie.offset
  let n = Moment.now()
  var s = collect(newSeq()):
    for index in namespaces:
      var reg = rdv.registered[index]
      if limit == 0:
        break
      if reg.expiration < n or index.uint64 < cookie.offset:
        continue
      limit.dec()
      nextOffset = index.uint64 + 1
      reg.data.ttl = Opt.some((reg.expiration - Moment.now()).seconds.uint64)
      reg.data
  rdv.rng.shuffle(s)
  await conn.sendDiscoverResponse(s, Cookie(offset: nextOffset, ns: d.ns))

proc advertisePeer(
    rdv: RendezVous, peer: PeerId, msg: seq[byte]
) {.async: (raises: [CancelledError]).} =
  proc advertiseWrap() {.async: (raises: []).} =
    try:
      let conn = await rdv.switch.dial(peer, RendezVousCodec)
      defer:
        await conn.close()
      await conn.writeLp(msg)
      let
        buf = await conn.readLp(4096)
        msgRecv = Message.decode(buf).tryGet()
      if msgRecv.msgType != MessageType.RegisterResponse:
        trace "Unexpected register response", peer, msgType = msgRecv.msgType
      elif msgRecv.registerResponse.tryGet().status != ResponseStatus.Ok:
        trace "Refuse to register", peer, response = msgRecv.registerResponse
      else:
        trace "Successfully registered", peer, response = msgRecv.registerResponse
    except CatchableError as exc:
      trace "exception in the advertise", description = exc.msg
    finally:
      rdv.sema.release()

  await rdv.sema.acquire()
  await advertiseWrap()

proc advertise*(
    rdv: RendezVous, ns: string, ttl: Duration, peers: seq[PeerId]
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  if ns.len < MinimumNamespaceLen or ns.len > MaximumNamespaceLen:
    raise newException(AdvertiseError, "Invalid namespace")

  if ttl < rdv.minDuration or ttl > rdv.maxDuration:
    raise newException(AdvertiseError, "Invalid time to live: " & $ttl)

  let sprBuff = rdv.switch.peerInfo.signedPeerRecord.encode().valueOr:
    raise newException(AdvertiseError, "Wrong Signed Peer Record")

  let
    r = Register(ns: ns, signedPeerRecord: sprBuff, ttl: Opt.some(ttl.seconds.uint64))
    msg = encode(Message(msgType: MessageType.Register, register: Opt.some(r)))

  rdv.save(ns, rdv.switch.peerInfo.peerId, r)

  let futs = collect(newSeq()):
    for peer in peers:
      trace "Send Advertise", peerId = peer, ns
      rdv.advertisePeer(peer, msg.buffer).withTimeout(5.seconds)

  await allFutures(futs)

method advertise*(
    rdv: RendezVous, ns: string, ttl: Duration = rdv.minDuration
) {.base, async: (raises: [CancelledError, AdvertiseError]).} =
  await rdv.advertise(ns, ttl, rdv.peers)

proc requestLocally*[T](rdv: RendezVous, ns: string): seq[T] =
  let
    nsSalted = ns & rdv.salt
    n = Moment.now()
  try:
    collect(newSeq()):
      for index in rdv.namespaces[nsSalted]:
        if rdv.registered[index].expiration > n:
          let res = SignedPayload[T].decode(rdv.registered[index].data.signedPeerRecord).valueOr:
            continue
          res.data
  except KeyError as exc:
    @[]

proc request*[T](
    rdv: RendezVous, ns: Opt[string], l: int = DiscoverLimit.int, peers: seq[PeerId]
): Future[seq[T]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  var
    s: Table[PeerId, (T, Register)]
    limit: uint64
    d = Discover(ns: ns)

  if l <= 0 or l > DiscoverLimit.int:
    raise newException(AdvertiseError, "Invalid limit")
  if ns.isSome() and ns.get().len > MaximumNamespaceLen:
    raise newException(AdvertiseError, "Invalid namespace")

  limit = l.uint64
  proc requestPeer(
      peer: PeerId
  ) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
    let conn = await rdv.switch.dial(peer, RendezVousCodec)
    defer:
      await conn.close()
    d.limit = Opt.some(limit)
    d.cookie =
      if ns.isSome():
        try:
          Opt.some(rdv.cookiesSaved[peer][ns.get()])
        except KeyError, CatchableError:
          Opt.none(seq[byte])
      else:
        Opt.none(seq[byte])
    await conn.writeLp(
      encode(Message(msgType: MessageType.Discover, discover: Opt.some(d))).buffer
    )
    let
      buf = await conn.readLp(MaximumMessageLen)
      msgRcv = Message.decode(buf).valueOr:
        debug "Message undecodable"
        return
    if msgRcv.msgType != MessageType.DiscoverResponse:
      debug "Unexpected discover response", msgType = msgRcv.msgType
      return
    let resp = msgRcv.discoverResponse.valueOr:
      debug "Discover response is empty"
      return
    if resp.status != ResponseStatus.Ok:
      trace "Cannot discover", ns, status = resp.status, text = resp.text
      return
    resp.cookie.withValue(cookie):
      if ns.isSome:
        let namespace = ns.get()
        if cookie.len() < 1000 and
            rdv.cookiesSaved.hasKeyOrPut(peer, {namespace: cookie}.toTable()):
          try:
            rdv.cookiesSaved[peer][namespace] = cookie
          except KeyError:
            raiseAssert "checked with hasKeyOrPut"
    for r in resp.registrations:
      if limit == 0:
        return
      let ttl = r.ttl.get(rdv.maxTTL + 1)
      if ttl > rdv.maxTTL:
        continue
      let
        spr = SignedPayload[T].decode(r.signedPeerRecord).valueOr:
          continue
        pr = spr.data
      if s.hasKey(pr.peerId):
        let (prSaved, rSaved) =
          try:
            s[pr.peerId]
          except KeyError:
            raiseAssert "checked with hasKey"
        if (prSaved.seqNo == pr.seqNo and rSaved.ttl.get(rdv.maxTTL) < ttl) or
            prSaved.seqNo < pr.seqNo:
          s[pr.peerId] = (pr, r)
      else:
        s[pr.peerId] = (pr, r)
      limit.dec()
    if ns.isSome():
      for (_, r) in s.values():
        rdv.save(ns.get(), peer, r, false)

  for peer in peers:
    if limit == 0:
      break
    if RendezVousCodec notin rdv.switch.peerStore[ProtoBook][peer]:
      continue
    try:
      trace "Send Request", peerId = peer, ns
      await peer.requestPeer()
    except CancelledError as e:
      raise e
    except DialFailedError as e:
      trace "failed to dial a peer", description = e.msg
    except LPStreamError as e:
      trace "failed to communicate with a peer", description = e.msg
  return toSeq(s.values()).mapIt(it[0])

proc request*[T](
    rdv: RendezVous, ns: Opt[string], l: int = DiscoverLimit.int
): Future[seq[T]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  await rdv.request[T](ns, l, rdv.peers)

proc request*[T](
    rdv: RendezVous, l: int = DiscoverLimit.int
): Future[seq[T]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  await rdv.request[T](Opt.none(string), l, rdv.peers)

proc unsubscribeLocally*(rdv: RendezVous, ns: string) =
  let nsSalted = ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == rdv.switch.peerInfo.peerId:
        rdv.registered[index].expiration = rdv.expiredDT
  except KeyError:
    return

proc unsubscribe*(
    rdv: RendezVous, ns: string, peerIds: seq[PeerId]
) {.async: (raises: [RendezVousError, CancelledError]).} =
  if ns.len < MinimumNamespaceLen or ns.len > MaximumNamespaceLen:
    raise newException(RendezVousError, "Invalid namespace")

  let msg = encode(
    Message(msgType: MessageType.Unregister, unregister: Opt.some(Unregister(ns: ns)))
  )

  proc unsubscribePeer(peerId: PeerId) {.async: (raises: []).} =
    try:
      let conn = await rdv.switch.dial(peerId, RendezVousCodec)
      defer:
        await conn.close()
      await conn.writeLp(msg.buffer)
    except CatchableError as exc:
      trace "exception while unsubscribing", description = exc.msg

  let futs = collect(newSeq()):
    for peer in peerIds:
      unsubscribePeer(peer)

  await allFutures(futs)

proc unsubscribe*(
    rdv: RendezVous, ns: string
) {.async: (raises: [RendezVousError, CancelledError]).} =
  rdv.unsubscribeLocally(ns)

  await rdv.unsubscribe(ns, rdv.peers)

proc setup*(rdv: RendezVous, switch: Switch) =
  rdv.switch = switch
  proc handlePeer(
      peerId: PeerId, event: PeerEvent
  ) {.async: (raises: [CancelledError]).} =
    if event.kind == PeerEventKind.Joined:
      rdv.peers.add(peerId)
    elif event.kind == PeerEventKind.Left:
      rdv.peers.keepItIf(it != peerId)

  rdv.switch.addPeerEventHandler(handlePeer, Joined)
  rdv.switch.addPeerEventHandler(handlePeer, Left)

proc new*(
    T: typedesc[RendezVous],
    rng: ref HmacDrbgContext = newRng(),
    minDuration = MinimumDuration,
    maxDuration = MaximumDuration,
): T {.raises: [RendezVousError].} =
  if minDuration < MinimumAcceptedDuration:
    raise newException(RendezVousError, "TTL too short: 1 minute minimum")

  if maxDuration > MaximumDuration:
    raise newException(RendezVousError, "TTL too long: 72 hours maximum")

  if minDuration >= maxDuration:
    raise newException(RendezVousError, "Minimum TTL longer than maximum")

  let
    minTTL = minDuration.seconds.uint64
    maxTTL = maxDuration.seconds.uint64

  let rdv = T(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](),
    expiredDT: Moment.now() - 1.days,
    #registerEvent: newAsyncEvent(),
    sema: newAsyncSemaphore(SemaphoreDefaultSize),
    minDuration: minDuration,
    maxDuration: maxDuration,
    minTTL: minTTL,
    maxTTL: maxTTL,
  )
  logScope:
    topics = "libp2p discovery rendezvous"
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let
        buf = await conn.readLp(4096)
        msg = Message.decode(buf).tryGet()
      case msg.msgType
      of MessageType.Register:
        await rdv.register(conn, msg.register.tryGet())
      of MessageType.RegisterResponse:
        trace "Got an unexpected Register Response", response = msg.registerResponse
      of MessageType.Unregister:
        rdv.unregister(conn, msg.unregister.tryGet())
      of MessageType.Discover:
        await rdv.discover(conn, msg.discover.tryGet())
      of MessageType.DiscoverResponse:
        trace "Got an unexpected Discover Response", response = msg.discoverResponse
    except CancelledError as exc:
      trace "cancelled rendezvous handler"
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", description = exc.msg
    finally:
      await conn.close()

  rdv.handler = handleStream
  rdv.codec = RendezVousCodec
  return rdv

proc new*(
    T: typedesc[RendezVous],
    switch: Switch,
    rng: ref HmacDrbgContext = newRng(),
    minDuration = MinimumDuration,
    maxDuration = MaximumDuration,
): T {.raises: [RendezVousError].} =
  let rdv = T.new(rng, minDuration, maxDuration)
  rdv.setup(switch)
  return rdv

proc deletesRegister*(
    rdv: RendezVous, interval = 1.minutes
) {.async: (raises: [CancelledError]).} =
  heartbeat "Register timeout", interval:
    let n = Moment.now()
    var total = 0
    rdv.registered.flushIfIt(it.expiration < n)
    for data in rdv.namespaces.mvalues():
      data.keepItIf(it >= rdv.registered.offset)
      total += data.len
    libp2p_rendezvous_registered.set(int64(total))
    libp2p_rendezvous_namespaces.set(int64(rdv.namespaces.len))

method start*(
    rdv: RendezVous
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if not rdv.registerDeletionLoop.isNil:
    warn "Starting rendezvous twice"
    return fut
  rdv.registerDeletionLoop = rdv.deletesRegister()
  rdv.started = true
  fut

method stop*(rdv: RendezVous): Future[void] {.async: (raises: [], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if rdv.registerDeletionLoop.isNil:
    warn "Stopping rendezvous without starting it"
    return fut
  rdv.started = false
  rdv.registerDeletionLoop.cancelSoon()
  rdv.registerDeletionLoop = nil
  fut

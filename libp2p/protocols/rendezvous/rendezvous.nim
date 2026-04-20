# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import tables, sequtils, sugar, sets
import metrics except collect
import
  chronos, chronicles, bearssl/rand, stew/[byteutils, objects], protobuf_serialization
import
  ./protobuf,
  ../protocol,
  ../../switch,
  ../../dial,
  ../../routing_record,
  ../../utils/heartbeat,
  ../../utils/future,
  ../../stream/connection,
  ../../utils/offsettedseq

export chronicles, offsettedseq, protobuf_serialization

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
  MinimumAcceptedDuration* = 1.minutes
  MaximumDuration* = 72.hours
  MaximumMessageLen = 1 shl 22 # 4MB
  MinimumNamespaceLen = 1
  MaximumNamespaceLen = 255
  RegistrationLimitPerPeer* = 1000
  DiscoverLimit = 1000'u64
  SemaphoreDefaultSize* = 5

type PeerRecordValidator*[E] =
  proc(_: E, spr: seq[byte], peerId: PeerId): Result[void, string] {.gcsafe.}

type
  AdvertiseError* = object of LPError
  RendezVousError* = object of LPError
  RegisteredData* = object
    expiration*: Moment
    peerId*: PeerId
    data*: Register

  # For any custom peer record type E, constructor has to be implemented
  GenericRendezVous*[E] = ref object of LPProtocol
    # Registered needs to be an offsetted sequence
    # because we need stable index for the cookies.
    registered*: OffsettedSeq[RegisteredData]
    # Namespaces is a table whose key is a salted namespace and
    # the value is the index sequence corresponding to this
    # namespace in the offsettedqueue.
    namespaces*: Table[string, seq[int]]
    rng*: ref HmacDrbgContext
    salt*: string
    expiredDT*: Moment
    registerDeletionLoop*: Future[void]
    #registerEvent: AsyncEvent # TODO: to raise during the heartbeat
    # + make the heartbeat sleep duration "smarter"
    sema*: AsyncSemaphore
    peers*: seq[PeerId]
    cookiesSaved*: Table[PeerId, Table[string, seq[byte]]]
    switch*: Switch
    minDuration*: Duration
    maxDuration*: Duration
    minTTL*: uint64
    maxTTL*: uint64
    peerRecordValidator*: PeerRecordValidator[E]

  RendezVous* = GenericRendezVous[PeerRecord]

proc checkPeerRecord*(
    _: PeerRecord, spr: seq[byte], peerId: PeerId
): Result[void, string] =
  if spr.len == 0:
    return err("Empty peer record")
  let signedEnv = ?SignedPeerRecord.decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()

proc sendRegisterResponse*(
    conn: Connection, ttl: uint64
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = Protobuf.encode(
    Message(
      msgType: pbSome(MsgTypeRegisterResponse),
      registerResponse:
        pbSome(RegisterResponse(status: pbSome(ResponseOk), ttl: pbSome(ttl))),
    )
  )
  await conn.writeLp(msg)

proc sendRegisterResponseError*(
    conn: Connection, status: ResponseStatus, text: string = ""
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = Protobuf.encode(
    Message(
      msgType: pbSome(MsgTypeRegisterResponse),
      registerResponse:
        pbSome(RegisterResponse(status: pbSome(status), text: pbSome(text))),
    )
  )
  await conn.writeLp(msg)

proc sendDiscoverResponse*(
    conn: Connection, s: seq[Register], cookie: Cookie
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = Protobuf.encode(
    Message(
      msgType: pbSome(MsgTypeDiscoverResponse),
      discoverResponse: pbSome(
        DiscoverResponse(
          status: pbSome(ResponseOk),
          registrations: s,
          cookie: pbSome(Protobuf.encode(cookie)),
        )
      ),
    )
  )
  await conn.writeLp(msg)

proc sendDiscoverResponseError*(
    conn: Connection, status: ResponseStatus, text: string = ""
) {.async: (raises: [CancelledError, LPStreamError]).} =
  let msg = Protobuf.encode(
    Message(
      msgType: pbSome(MsgTypeDiscoverResponse),
      discoverResponse:
        pbSome(DiscoverResponse(status: pbSome(status), text: pbSome(text))),
    )
  )
  await conn.writeLp(msg)

proc countRegister*[E](rdv: GenericRendezVous[E], peerId: PeerId): int =
  for data in rdv.registered:
    if data.peerId == peerId:
      result.inc()

proc save*[E](
    rdv: GenericRendezVous[E],
    ns: string,
    peerId: PeerId,
    r: Register,
    update: bool = true,
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
        peerId: peerId, expiration: Moment.now() + r.ttl.valueOr(rdv.minTTL).int64.seconds, data: r
      )
    )
    rdv.namespaces[nsSalted].add(rdv.registered.high)
  #    rdv.registerEvent.fire()
  except exceptions.KeyError as e:
    raiseAssert "Should have key: " & e.msg

proc register*[E](
    rdv: GenericRendezVous[E], conn: Connection, r: Register, peerRecord: E
): Future[void] =
  trace "Received Register", peerId = conn.peerId, ns = r.ns
  libp2p_rendezvous_register.inc()
  if r.ns.get().len < MinimumNamespaceLen or r.ns.get().len > MaximumNamespaceLen:
    return conn.sendRegisterResponseError(ResponseInvalidNamespace)
  let ttl = r.ttl.valueOr(rdv.minTTL)
  if ttl < rdv.minTTL or ttl > rdv.maxTTL:
    return conn.sendRegisterResponseError(ResponseInvalidTTL)
  let pr = rdv.peerRecordValidator(peerRecord, r.signedPeerRecord.get(), conn.peerId)
  if pr.isErr():
    return conn.sendRegisterResponseError(ResponseInvalidSignedPeerRecord, pr.error())
  if rdv.countRegister(conn.peerId) >= RegistrationLimitPerPeer:
    return conn.sendRegisterResponseError(
      ResponseNotAuthorized, "Registration limit reached"
    )

  rdv.save(r.ns.get(), conn.peerId, r)
  libp2p_rendezvous_registered.inc()
  libp2p_rendezvous_namespaces.set(int64(rdv.namespaces.len))
  conn.sendRegisterResponse(ttl)

proc unregister*[E](rdv: GenericRendezVous[E], conn: Connection, u: Unregister) =
  trace "Received Unregister", peerId = conn.peerId, ns = u.ns
  let nsSalted = u.ns.get() & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == conn.peerId:
        rdv.registered[index].expiration = rdv.expiredDT
        libp2p_rendezvous_registered.dec()
  except exceptions.KeyError:
    return

proc discover*[E](
    rdv: GenericRendezVous[E], conn: Connection, d: Discover
) {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Received Discover", peerId = conn.peerId, ns = d.ns
  libp2p_rendezvous_discover.inc()
  if d.ns.get().len > MaximumNamespaceLen:
    await conn.sendDiscoverResponseError(ResponseInvalidNamespace)
    return
  var limit = min(
    DiscoverLimit,
    if d.limit.isSome():
      d.limit.get()
    else:
      DiscoverLimit,
  )
  var cookie =
    if d.cookie.isSome():
      try:
        Protobuf.decode(d.cookie.get(), Cookie)
      except SerializationError:
        await conn.sendDiscoverResponseError(ResponseInvalidCookie)
        return
    else:
      # Start from the current lowest index (inclusive)
      Cookie(offset: pbSome(rdv.registered.low().uint64))
  if cookie.offset.isNone():
    await conn.sendDiscoverResponseError(ResponseInvalidCookie)
    return
  if d.ns.isSome() and cookie.ns.isSome() and cookie.ns.get() != d.ns.get():
    # Namespace changed: start from the beginning of that namespace
    cookie = Cookie(offset: pbSome(rdv.registered.low().uint64))
  elif cookie.offset.get() < rdv.registered.low().uint64:
    # Cookie behind available range: reset to current low
    cookie.offset = pbSome(rdv.registered.low().uint64)
  elif cookie.offset.get() > (rdv.registered.high() + 1).uint64:
    # Cookie ahead of available range: reset to one past current high (empty page)
    cookie.offset = pbSome((rdv.registered.high() + 1).uint64)
  let namespaces =
    if d.ns.isSome():
      try:
        rdv.namespaces[d.ns.get() & rdv.salt]
      except exceptions.KeyError:
        await conn.sendDiscoverResponseError(ResponseInvalidNamespace)
        return
    else:
      toSeq(
        max(cookie.offset.get().int, rdv.registered.offset) .. rdv.registered.high()
      )
  if namespaces.len() == 0:
    await conn.sendDiscoverResponse(@[], Cookie())
    return
  var nextOffset = cookie.offset.get()
  let n = Moment.now()
  var s: seq[Register] = @[]
  for index in namespaces:
    var reg = rdv.registered[index]
    if limit == 0:
      break
    if reg.expiration < n or index.uint64 < cookie.offset.get():
      continue
    limit.dec()
    nextOffset = index.uint64 + 1
    reg.data.ttl = pbSome((reg.expiration - Moment.now()).seconds.uint64)
    s.add(reg.data)
  rdv.rng.shuffle(s)
  await conn.sendDiscoverResponse(s, Cookie(offset: pbSome(nextOffset), ns: d.ns))

proc advertisePeer[E](
    rdv: GenericRendezVous[E], peer: PeerId, msg: seq[byte]
) {.async: (raises: [CancelledError]).} =
  proc advertiseWrap() {.async: (raises: []).} =
    try:
      let conn = await rdv.switch.dial(peer, rdv.codec)
      defer:
        await conn.close()
      await conn.writeLp(msg)
      let
        buf = await conn.readLp(4096)
        msgRecv = Protobuf.decode(buf, Message)
      if msgRecv.msgType.get() != MsgTypeRegisterResponse:
        trace "Unexpected register response", peer, msgType = msgRecv.msgType
      elif msgRecv.registerResponse.get().status.get() != ResponseOk:
        trace "Refuse to register", peer, response = msgRecv.registerResponse
      else:
        trace "Successfully registered", peer, response = msgRecv.registerResponse
    except CatchableError as exc:
      trace "exception in the advertise", description = exc.msg
    finally:
      try:
        rdv.sema.release()
      except AsyncSemaphoreError:
        raiseAssert "semaphore released without acquire"

  await rdv.sema.acquire()
  await advertiseWrap()

proc advertise*[E](
    rdv: GenericRendezVous[E],
    ns: string,
    customPeerRecord: E,
    ttl: Duration,
    peers: seq[PeerId],
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  let signedPeerRecord = SignedPayload[E].init(
    rdv.switch.peerInfo.privateKey, customPeerRecord
  ).valueOr:
    info "Can't create the signed peer record", error = error
    return

  let pBuff = signedPeerRecord.encode().valueOr:
    raise newException(AdvertiseError, "Wrong Custom Peer Record")
  await rdv.advertise(ns, ttl, peers, Opt.some(pBuff))

proc advertise*[E](
    rdv: GenericRendezVous[E],
    ns: string,
    ttl: Duration,
    peers: seq[PeerId],
    sprBuff: seq[byte],
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  if ns.len < MinimumNamespaceLen or ns.len > MaximumNamespaceLen:
    raise newException(AdvertiseError, "Invalid namespace")

  if ttl < rdv.minDuration or ttl > rdv.maxDuration:
    raise newException(AdvertiseError, "Invalid time to live: " & $ttl)

  let
    r = Register(
      ns: pbSome(ns), signedPeerRecord: pbSome(sprBuff), ttl: pbSome(ttl.seconds.uint64)
    )
    msg =
      Protobuf.encode(Message(msgType: pbSome(MsgTypeRegister), register: pbSome(r)))

  rdv.save(ns, rdv.switch.peerInfo.peerId, r)

  let futs = collect(newSeq()):
    for peer in peers:
      trace "Send Advertise", peerId = peer, ns
      rdv.advertisePeer(peer, msg).withTimeout(5.seconds)

  await allFutures(futs)

method advertise*(
    rdv: RendezVous, ns: string, ttl: Opt[Duration] = Opt.none(Duration)
) {.base, async: (raises: [CancelledError, AdvertiseError]).} =
  let lttl = ttl.get(rdv.minDuration)
  if rdv.switch.isNil:
    # I don't like this, but adding this as i don't understand why we have a constructor without switch as arg
    raise newException(AdvertiseError, "Rendezvous not setup with a switch")
  let sprBuff = rdv.switch.peerInfo.signedPeerRecord.encode().valueOr:
    raise newException(AdvertiseError, "Wrong Signed Peer Record")
  await rdv.advertise(ns, lttl, rdv.peers, sprBuff)

proc requestLocally*[E](rdv: GenericRendezVous[E], ns: string): seq[E] =
  let
    nsSalted = ns & rdv.salt
    n = Moment.now()
  try:
    collect(newSeq()):
      for index in rdv.namespaces[nsSalted]:
        if rdv.registered[index].expiration > n:
          let res = SignedPayload[E].decode(
            rdv.registered[index].data.signedPeerRecord.get()
          ).valueOr:
            continue
          res.data
  except exceptions.KeyError:
    @[]

proc requestPeer[E](
    rdv: GenericRendezVous[E], limit: uint64, ns: Opt[string], peer: PeerId
): Future[seq[Register]] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError])
.} =
  let conn = await rdv.switch.dial(peer, rdv.codec)
  defer:
    await conn.close()

  let disns = if ns.isSome(): pbSome(ns.get()) else: pbNone(default(string))
  var d = Discover(ns: disns, limit: pbSome(limit))
  d.cookie =
    if ns.isSome():
      try:
        pbSome(rdv.cookiesSaved[peer][ns.get()])
      except exceptions.KeyError:
        pbNone(default(seq[byte]))
    else:
      pbNone(default(seq[byte]))
  await conn.writeLp(
    Protobuf.encode(Message(msgType: pbSome(MsgTypeDiscover), discover: pbSome(d)))
  )
  let buf = await conn.readLp(MaximumMessageLen)
  let msgRcv =
    try:
      Protobuf.decode(buf, Message)
    except SerializationError:
      debug "Message undecodable"
      return @[]
  if msgRcv.msgType.get() != MsgTypeDiscoverResponse:
    debug "Unexpected discover response", msgType = msgRcv.msgType
    return @[]
  if msgRcv.discoverResponse.isNone():
    debug "Discover response is empty"
    return @[]
  let resp = msgRcv.discoverResponse.get()
  if resp.status.get() != ResponseOk:
    trace "Cannot discover", ns, status = resp.status, text = resp.text
    return @[]
  if resp.cookie.isSome:
    if ns.isSome:
      let namespace = ns.get()
      if resp.cookie.get().len < 1000 and
          rdv.cookiesSaved.hasKeyOrPut(peer, {namespace: resp.cookie.get()}.toTable()):
        try:
          rdv.cookiesSaved[peer][namespace] = resp.cookie.get()
        except exceptions.KeyError:
          raiseAssert "checked with hasKeyOrPut"
  return resp.registrations

proc request*[E](
    rdv: GenericRendezVous[E], ns: Opt[string], lt: Opt[int], peersOpt: Opt[seq[PeerId]]
): Future[seq[E]] {.async: (raises: [LPError, CancelledError]).} =
  var
    s: Table[PeerId, (E, Register)]
    limit: uint64
  let l = lt.get(DiscoverLimit.int)
  let peers = peersOpt.get(rdv.peers)
  if l <= 0 or l > DiscoverLimit.int:
    raise newException(AdvertiseError, "Invalid limit")
  if ns.isSome() and ns.get().len > MaximumNamespaceLen:
    raise newException(AdvertiseError, "Invalid namespace")

  limit = l.uint64

  for peer in peers:
    if limit == 0:
      break
    if rdv.codec notin rdv.switch.peerStore[ProtoBook][peer]:
      continue
    try:
      trace "Send Request", peerId = peer, ns
      let registrations = await rdv.requestPeer(limit, ns, peer)
      for r in registrations:
        if limit == 0:
          break
        let ttl = r.ttl.valueOr(rdv.maxTTL + 1)
        if ttl > rdv.maxTTL:
          continue
        let
          spr = SignedPayload[E].decode(r.signedPeerRecord.get()).valueOr:
            continue
          pr = spr.data
        if s.hasKey(pr.peerId):
          let (prSaved, rSaved) =
            try:
              s[pr.peerId]
            except exceptions.KeyError:
              raiseAssert "checked with hasKey"
          if (prSaved.seqNo == pr.seqNo and rSaved.ttl.valueOr(rdv.maxTTL) < ttl) or
              prSaved.seqNo < pr.seqNo:
            s[pr.peerId] = (pr, r)
        else:
          s[pr.peerId] = (pr, r)
        limit.dec()
      if ns.isSome():
        for (_, r) in s.values():
          rdv.save(ns.get(), peer, r, false)
    except CancelledError as e:
      raise e
    except DialFailedError as e:
      trace "failed to dial a peer", description = e.msg
    except LPStreamError as e:
      trace "failed to communicate with a peer", description = e.msg
  return toSeq(s.values()).mapIt(it[0])

proc unsubscribeLocally*[E](rdv: GenericRendezVous[E], ns: string) =
  let nsSalted = ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == rdv.switch.peerInfo.peerId:
        rdv.registered[index].expiration = rdv.expiredDT
  except exceptions.KeyError:
    return

proc unsubscribe*[E](
    rdv: GenericRendezVous[E], ns: string, peerIds: seq[PeerId]
) {.async: (raises: [RendezVousError, CancelledError]).} =
  if ns.len < MinimumNamespaceLen or ns.len > MaximumNamespaceLen:
    raise newException(RendezVousError, "Invalid namespace")

  let msg = Protobuf.encode(
    Message(
      msgType: pbSome(MsgTypeUnregister), unregister: pbSome(Unregister(ns: pbSome(ns)))
    )
  )

  proc unsubscribePeer(peerId: PeerId) {.async: (raises: []).} =
    try:
      let conn = await rdv.switch.dial(peerId, RendezVousCodec)
      defer:
        await conn.close()
      await conn.writeLp(msg)
    except CatchableError as exc:
      trace "exception while unsubscribing", description = exc.msg

  let futs = collect(newSeq()):
    for peer in peerIds:
      unsubscribePeer(peer)

  await allFutures(futs)

proc unsubscribe*[E](
    rdv: GenericRendezVous[E], ns: string
) {.async: (raises: [RendezVousError, CancelledError]).} =
  rdv.unsubscribeLocally(ns)

  await rdv.unsubscribe(ns, rdv.peers)

proc setup*[E](rdv: GenericRendezVous[E], switch: Switch) =
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
    codec: string,
): T =
  var minD = minDuration
  var maxD = maxDuration
  if minD < MinimumAcceptedDuration:
    warn "TTL too short: 1 minute minimum"
    minD = MinimumAcceptedDuration

  if maxD > MaximumDuration:
    warn "TTL too long: 72 hours maximum"
    maxD = MaximumDuration

  if minD >= maxD:
    warn "Minimum TTL longer than maximum"
    minD = MinimumAcceptedDuration
    maxD = MaximumDuration

  let
    minTTL = minD.seconds.uint64
    maxTTL = maxD.seconds.uint64

  let rdv = GenericRendezVous[PeerRecord](
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
    peerRecordValidator: checkPeerRecord,
  )
  logScope:
    topics = "libp2p discovery rendezvous"
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let
        buf = await conn.readLp(4096)
        msg = Protobuf.decode(buf, Message)
      case msg.msgType.get()
      of MsgTypeRegister:
        await rdv.register(
          conn, msg.register.get(), rdv.switch.peerInfo.signedPeerRecord.data
        )
      of MsgTypeRegisterResponse:
        trace "Got an unexpected Register Response", response = msg.registerResponse
      of MsgTypeUnregister:
        rdv.unregister(conn, msg.unregister.get())
      of MsgTypeDiscover:
        await rdv.discover(conn, msg.discover.get())
      of MsgTypeDiscoverResponse:
        trace "Got an unexpected Discover Response", response = msg.discoverResponse
      else:
        trace "Got an unexpected Message type", msgType = msg.msgType
    except CancelledError as exc:
      trace "cancelled rendezvous handler"
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", description = exc.msg
    finally:
      await conn.close()

  info "Rendezvous protocol initialized", codec
  rdv.handler = handleStream
  rdv.codec = codec
  return rdv

proc new*(
    T: typedesc[RendezVous],
    rng: ref HmacDrbgContext = newRng(),
    minDuration = MinimumDuration,
    maxDuration = MaximumDuration,
): T =
  result = T.new(rng, minDuration, maxDuration, RendezVousCodec)

proc new*(
    T: typedesc[RendezVous],
    switch: Switch,
    rng: ref HmacDrbgContext = newRng(),
    minDuration = MinimumDuration,
    maxDuration = MaximumDuration,
): T =
  let rdv = T.new(rng, minDuration, maxDuration, RendezVousCodec)
  rdv.setup(switch)
  return rdv

proc deletesRegister*[E](
    rdv: GenericRendezVous[E], interval = 1.minutes
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

method start*[E](
    rdv: GenericRendezVous[E]
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  let fut = newFutureCompleted[void]()
  if not rdv.registerDeletionLoop.isNil:
    warn "Starting rendezvous twice"
    return fut
  rdv.registerDeletionLoop = rdv.deletesRegister()
  rdv.started = true
  fut

method stop*[E](
    rdv: GenericRendezVous[E]
): Future[void] {.async: (raises: [], raw: true).} =
  if rdv.registerDeletionLoop.isNil:
    warn "Stopping rendezvous without starting it"
    return newFutureCompleted[void]()

  rdv.started = false
  rdv.registerDeletionLoop.cancelSoon()
  rdv.registerDeletionLoop = nil
  newFutureCompleted[void]()

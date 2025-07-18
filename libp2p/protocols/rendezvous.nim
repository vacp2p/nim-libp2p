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
  ./protocol,
  ../protobuf/minprotobuf,
  ../switch,
  ../routing_record,
  ../utils/heartbeat,
  ../stream/connection,
  ../utils/offsettedseq,
  ../utils/semaphore,
  ../discovery/discoverymngr

export chronicles

logScope:
  topics = "libp2p discovery rendezvous"

declareCounter(libp2p_rendezvous_register, "number of advertise requests")
declareCounter(libp2p_rendezvous_discover, "number of discovery requests")
declareGauge(libp2p_rendezvous_registered, "number of registered peers")
declareGauge(libp2p_rendezvous_namespaces, "number of registered namespaces")

const
  RendezVousCodec* = "/rendezvous/1.0.0"
  MinimumDuration* = 2.hours
  MaximumDuration = 72.hours
  MaximumMessageLen = 1 shl 22 # 4MB
  MinimumNamespaceLen = 1
  MaximumNamespaceLen = 255
  RegistrationLimitPerPeer = 1000
  DiscoverLimit = 1000'u64
  SemaphoreDefaultSize = 5

type
  MessageType {.pure.} = enum
    Register = 0
    RegisterResponse = 1
    Unregister = 2
    Discover = 3
    DiscoverResponse = 4

  ResponseStatus = enum
    Ok = 0
    InvalidNamespace = 100
    InvalidSignedPeerRecord = 101
    InvalidTTL = 102
    InvalidCookie = 103
    NotAuthorized = 200
    InternalError = 300
    Unavailable = 400

  Cookie = object
    offset: uint64
    ns: Opt[string]

  Register = object
    ns: string
    signedPeerRecord: seq[byte]
    ttl: Opt[uint64] # in seconds

  RegisterResponse = object
    status: ResponseStatus
    text: Opt[string]
    ttl: Opt[uint64] # in seconds

  Unregister = object
    ns: string

  Discover = object
    ns: Opt[string]
    limit: Opt[uint64]
    cookie: Opt[seq[byte]]

  DiscoverResponse = object
    registrations: seq[Register]
    cookie: Opt[seq[byte]]
    status: ResponseStatus
    text: Opt[string]

  Message = object
    msgType: MessageType
    register: Opt[Register]
    registerResponse: Opt[RegisterResponse]
    unregister: Opt[Unregister]
    discover: Opt[Discover]
    discoverResponse: Opt[DiscoverResponse]

proc encode(c: Cookie): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, c.offset)
  if c.ns.isSome():
    result.write(2, c.ns.get())
  result.finish()

proc encode(r: Register): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, r.ns)
  result.write(2, r.signedPeerRecord)
  r.ttl.withValue(ttl):
    result.write(3, ttl)
  result.finish()

proc encode(rr: RegisterResponse): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, rr.status.uint)
  rr.text.withValue(text):
    result.write(2, text)
  rr.ttl.withValue(ttl):
    result.write(3, ttl)
  result.finish()

proc encode(u: Unregister): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, u.ns)
  result.finish()

proc encode(d: Discover): ProtoBuffer =
  result = initProtoBuffer()
  if d.ns.isSome():
    result.write(1, d.ns.get())
  d.limit.withValue(limit):
    result.write(2, limit)
  d.cookie.withValue(cookie):
    result.write(3, cookie)
  result.finish()

proc encode(dr: DiscoverResponse): ProtoBuffer =
  result = initProtoBuffer()
  for reg in dr.registrations:
    result.write(1, reg.encode())
  dr.cookie.withValue(cookie):
    result.write(2, cookie)
  result.write(3, dr.status.uint)
  dr.text.withValue(text):
    result.write(4, text)
  result.finish()

proc encode(msg: Message): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, msg.msgType.uint)
  msg.register.withValue(register):
    result.write(2, register.encode())
  msg.registerResponse.withValue(registerResponse):
    result.write(3, registerResponse.encode())
  msg.unregister.withValue(unregister):
    result.write(4, unregister.encode())
  msg.discover.withValue(discover):
    result.write(5, discover.encode())
  msg.discoverResponse.withValue(discoverResponse):
    result.write(6, discoverResponse.encode())
  result.finish()

proc decode(_: typedesc[Cookie], buf: seq[byte]): Opt[Cookie] =
  var
    c: Cookie
    ns: string
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, c.offset)
    r2 = pb.getField(2, ns)
  if r1.isErr() or r2.isErr():
    return Opt.none(Cookie)
  if r2.get(false):
    c.ns = Opt.some(ns)
  Opt.some(c)

proc decode(_: typedesc[Register], buf: seq[byte]): Opt[Register] =
  var
    r: Register
    ttl: uint64
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, r.ns)
    r2 = pb.getRequiredField(2, r.signedPeerRecord)
    r3 = pb.getField(3, ttl)
  if r1.isErr() or r2.isErr() or r3.isErr():
    return Opt.none(Register)
  if r3.get(false):
    r.ttl = Opt.some(ttl)
  Opt.some(r)

proc decode(_: typedesc[RegisterResponse], buf: seq[byte]): Opt[RegisterResponse] =
  var
    rr: RegisterResponse
    statusOrd: uint
    text: string
    ttl: uint64
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, statusOrd)
    r2 = pb.getField(2, text)
    r3 = pb.getField(3, ttl)
  if r1.isErr() or r2.isErr() or r3.isErr() or
      not checkedEnumAssign(rr.status, statusOrd):
    return Opt.none(RegisterResponse)
  if r2.get(false):
    rr.text = Opt.some(text)
  if r3.get(false):
    rr.ttl = Opt.some(ttl)
  Opt.some(rr)

proc decode(_: typedesc[Unregister], buf: seq[byte]): Opt[Unregister] =
  var u: Unregister
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, u.ns)
  if r1.isErr():
    return Opt.none(Unregister)
  Opt.some(u)

proc decode(_: typedesc[Discover], buf: seq[byte]): Opt[Discover] =
  var
    d: Discover
    limit: uint64
    cookie: seq[byte]
    ns: string
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getField(1, ns)
    r2 = pb.getField(2, limit)
    r3 = pb.getField(3, cookie)
  if r1.isErr() or r2.isErr() or r3.isErr:
    return Opt.none(Discover)
  if r1.get(false):
    d.ns = Opt.some(ns)
  if r2.get(false):
    d.limit = Opt.some(limit)
  if r3.get(false):
    d.cookie = Opt.some(cookie)
  Opt.some(d)

proc decode(_: typedesc[DiscoverResponse], buf: seq[byte]): Opt[DiscoverResponse] =
  var
    dr: DiscoverResponse
    registrations: seq[seq[byte]]
    cookie: seq[byte]
    statusOrd: uint
    text: string
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRepeatedField(1, registrations)
    r2 = pb.getField(2, cookie)
    r3 = pb.getRequiredField(3, statusOrd)
    r4 = pb.getField(4, text)
  if r1.isErr() or r2.isErr() or r3.isErr or r4.isErr() or
      not checkedEnumAssign(dr.status, statusOrd):
    return Opt.none(DiscoverResponse)
  for reg in registrations:
    var r: Register
    let regOpt = Register.decode(reg).valueOr:
      return
    dr.registrations.add(regOpt)
  if r2.get(false):
    dr.cookie = Opt.some(cookie)
  if r4.get(false):
    dr.text = Opt.some(text)
  Opt.some(dr)

proc decode(_: typedesc[Message], buf: seq[byte]): Opt[Message] =
  var
    msg: Message
    statusOrd: uint
    pbr, pbrr, pbu, pbd, pbdr: ProtoBuffer
  let pb = initProtoBuffer(buf)

  ?pb.getRequiredField(1, statusOrd).toOpt
  if not checkedEnumAssign(msg.msgType, statusOrd):
    return Opt.none(Message)

  if ?pb.getField(2, pbr).optValue:
    msg.register = Register.decode(pbr.buffer)
    if msg.register.isNone():
      return Opt.none(Message)

  if ?pb.getField(3, pbrr).optValue:
    msg.registerResponse = RegisterResponse.decode(pbrr.buffer)
    if msg.registerResponse.isNone():
      return Opt.none(Message)

  if ?pb.getField(4, pbu).optValue:
    msg.unregister = Unregister.decode(pbu.buffer)
    if msg.unregister.isNone():
      return Opt.none(Message)

  if ?pb.getField(5, pbd).optValue:
    msg.discover = Discover.decode(pbd.buffer)
    if msg.discover.isNone():
      return Opt.none(Message)

  if ?pb.getField(6, pbdr).optValue:
    msg.discoverResponse = DiscoverResponse.decode(pbdr.buffer)
    if msg.discoverResponse.isNone():
      return Opt.none(Message)

  Opt.some(msg)

type
  RendezVousError* = object of DiscoveryError
  RegisteredData = object
    expiration: Moment
    peerId: PeerId
    data: Register

  RendezVous* = ref object of LPProtocol
    # Registered needs to be an offsetted sequence
    # because we need stable index for the cookies.
    registered: OffsettedSeq[RegisteredData]
    # Namespaces is a table whose key is a salted namespace and
    # the value is the index sequence corresponding to this
    # namespace in the offsettedqueue.
    namespaces: Table[string, seq[int]]
    rng: ref HmacDrbgContext
    salt: string
    defaultDT: Moment
    registerDeletionLoop: Future[void]
    #registerEvent: AsyncEvent # TODO: to raise during the heartbeat
    # + make the heartbeat sleep duration "smarter"
    sema: AsyncSemaphore
    peers: seq[PeerId]
    cookiesSaved: Table[PeerId, Table[string, seq[byte]]]
    switch: Switch
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
  let n = Moment.now()
  for data in rdv.registered:
    if data.peerId == peerId and data.expiration > n:
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
        rdv.registered[index].expiration = rdv.defaultDT
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

proc unregister(rdv: RendezVous, conn: Connection, u: Unregister) =
  trace "Received Unregister", peerId = conn.peerId, ns = u.ns
  let nsSalted = u.ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == conn.peerId:
        rdv.registered[index].expiration = rdv.defaultDT
        libp2p_rendezvous_registered.dec()
  except KeyError:
    return

proc discover(
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
      Cookie(offset: rdv.registered.low().uint64 - 1)
  if d.ns.isSome() and cookie.ns.isSome() and cookie.ns.get() != d.ns.get() or
      cookie.offset < rdv.registered.low().uint64 or
      cookie.offset > rdv.registered.high().uint64:
    cookie = Cookie(offset: rdv.registered.low().uint64 - 1)
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
  var offset = namespaces[^1]
  let n = Moment.now()
  var s = collect(newSeq()):
    for index in namespaces:
      var reg = rdv.registered[index]
      if limit == 0:
        offset = index
        break
      if reg.expiration < n or index.uint64 <= cookie.offset:
        continue
      limit.dec()
      reg.data.ttl = Opt.some((reg.expiration - Moment.now()).seconds.uint64)
      reg.data
  rdv.rng.shuffle(s)
  await conn.sendDiscoverResponse(s, Cookie(offset: offset.uint64, ns: d.ns))

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

proc requestLocally*(rdv: RendezVous, ns: string): seq[PeerRecord] =
  let
    nsSalted = ns & rdv.salt
    n = Moment.now()
  try:
    collect(newSeq()):
      for index in rdv.namespaces[nsSalted]:
        if rdv.registered[index].expiration > n:
          let res = SignedPeerRecord.decode(rdv.registered[index].data.signedPeerRecord).valueOr:
            continue
          res.data
  except KeyError as exc:
    @[]

proc request*(
    rdv: RendezVous, ns: Opt[string], l: int = DiscoverLimit.int, peers: seq[PeerId]
): Future[seq[PeerRecord]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  var
    s: Table[PeerId, (PeerRecord, Register)]
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
        spr = SignedPeerRecord.decode(r.signedPeerRecord).valueOr:
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

proc request*(
    rdv: RendezVous, ns: Opt[string], l: int = DiscoverLimit.int
): Future[seq[PeerRecord]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  await rdv.request(ns, l, rdv.peers)

proc request*(
    rdv: RendezVous, l: int = DiscoverLimit.int
): Future[seq[PeerRecord]] {.async: (raises: [DiscoveryError, CancelledError]).} =
  await rdv.request(Opt.none(string), l, rdv.peers)

proc unsubscribeLocally*(rdv: RendezVous, ns: string) =
  let nsSalted = ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == rdv.switch.peerInfo.peerId:
        rdv.registered[index].expiration = rdv.defaultDT
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
  if minDuration < 1.minutes:
    raise newException(RendezVousError, "TTL too short: 1 minute minimum")

  if maxDuration > 72.hours:
    raise newException(RendezVousError, "TTL too long: 72 hours maximum")

  if minDuration >= maxDuration:
    raise newException(RendezVousError, "Minimum TTL longer than maximum")

  let
    minTTL = minDuration.seconds.uint64
    maxTTL = maxDuration.seconds.uint64

  let rdv = T(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](1),
    defaultDT: Moment.now() - 1.days,
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

proc deletesRegister(
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

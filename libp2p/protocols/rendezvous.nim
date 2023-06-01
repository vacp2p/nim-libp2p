# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import tables, sequtils, sugar, sets, options
import chronos,
       chronicles,
       bearssl/rand,
       stew/[byteutils, objects]
import ./protocol,
       ../switch,
       ../routing_record,
       ../utils/heartbeat,
       ../stream/connection,
       ../utils/offsettedseq,
       ../utils/semaphore

export chronicles

logScope:
  topics = "libp2p discovery rendezvous"

const
  RendezVousCodec* = "/rendezvous/1.0.0"
  MinimumDuration* = 2.hours
  MaximumDuration = 72.hours
  MinimumTTL = MinimumDuration.seconds.uint64
  MaximumTTL = MaximumDuration.seconds.uint64
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
    offset : uint64
    ns : string

  Register = object
    ns : string
    signedPeerRecord: seq[byte]
    ttl: Option[uint64] # in seconds

  RegisterResponse = object
    status: ResponseStatus
    text: Option[string]
    ttl: Option[uint64] # in seconds

  Unregister = object
    ns: string

  Discover = object
    ns: string
    limit: Option[uint64]
    cookie: Option[seq[byte]]

  DiscoverResponse = object
    registrations: seq[Register]
    cookie: Option[seq[byte]]
    status: ResponseStatus
    text: Option[string]

  Message = object
    msgType: MessageType
    register: Option[Register]
    registerResponse: Option[RegisterResponse]
    unregister: Option[Unregister]
    discover: Option[Discover]
    discoverResponse: Option[DiscoverResponse]

proc encode(c: Cookie): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, c.offset)
  result.write(2, c.ns)
  result.finish()

proc encode(r: Register): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, r.ns)
  result.write(2, r.signedPeerRecord)
  if r.ttl.isSome():
    result.write(3, r.ttl.get())
  result.finish()

proc encode(rr: RegisterResponse): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, rr.status.uint)
  if rr.text.isSome():
    result.write(2, rr.text.get())
  if rr.ttl.isSome():
    result.write(3, rr.ttl.get())
  result.finish()

proc encode(u: Unregister): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, u.ns)
  result.finish()

proc encode(d: Discover): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, d.ns)
  if d.limit.isSome():
    result.write(2, d.limit.get())
  if d.cookie.isSome():
    result.write(3, d.cookie.get())
  result.finish()

proc encode(d: DiscoverResponse): ProtoBuffer =
  result = initProtoBuffer()
  for reg in d.registrations:
    result.write(1, reg.encode())
  if d.cookie.isSome():
    result.write(2, d.cookie.get())
  result.write(3, d.status.uint)
  if d.text.isSome():
    result.write(4, d.text.get())
  result.finish()

proc encode(msg: Message): ProtoBuffer =
  result = initProtoBuffer()
  result.write(1, msg.msgType.uint)
  if msg.register.isSome():
    result.write(2, msg.register.get().encode())
  if msg.registerResponse.isSome():
    result.write(3, msg.registerResponse.get().encode())
  if msg.unregister.isSome():
    result.write(4, msg.unregister.get().encode())
  if msg.discover.isSome():
    result.write(5, msg.discover.get().encode())
  if msg.discoverResponse.isSome():
    result.write(6, msg.discoverResponse.get().encode())
  result.finish()

proc decode(_: typedesc[Cookie], buf: seq[byte]): Option[Cookie] =
  var c: Cookie
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, c.offset)
    r2 = pb.getRequiredField(2, c.ns)
  if r1.isErr() or r2.isErr(): return none(Cookie)
  some(c)

proc decode(_: typedesc[Register], buf: seq[byte]): Option[Register] =
  var
    r: Register
    ttl: uint64
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, r.ns)
    r2 = pb.getRequiredField(2, r.signedPeerRecord)
    r3 = pb.getField(3, ttl)
  if r1.isErr() or r2.isErr() or r3.isErr(): return none(Register)
  if r3.get(): r.ttl = some(ttl)
  some(r)

proc decode(_: typedesc[RegisterResponse], buf: seq[byte]): Option[RegisterResponse] =
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
     not checkedEnumAssign(rr.status, statusOrd): return none(RegisterResponse)
  if r2.get(): rr.text = some(text)
  if r3.get(): rr.ttl = some(ttl)
  some(rr)

proc decode(_: typedesc[Unregister], buf: seq[byte]): Option[Unregister] =
  var u: Unregister
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, u.ns)
  if r1.isErr(): return none(Unregister)
  some(u)

proc decode(_: typedesc[Discover], buf: seq[byte]): Option[Discover] =
  var
    d: Discover
    limit: uint64
    cookie: seq[byte]
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, d.ns)
    r2 = pb.getField(2, limit)
    r3 = pb.getField(3, cookie)
  if r1.isErr() or r2.isErr() or r3.isErr: return none(Discover)
  if r2.get(): d.limit = some(limit)
  if r3.get(): d.cookie = some(cookie)
  some(d)

proc decode(_: typedesc[DiscoverResponse], buf: seq[byte]): Option[DiscoverResponse] =
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
     not checkedEnumAssign(dr.status, statusOrd): return none(DiscoverResponse)
  for reg in registrations:
    var r: Register
    let regOpt = Register.decode(reg)
    if regOpt.isNone(): return none(DiscoverResponse)
    dr.registrations.add(regOpt.get())
  if r2.get(): dr.cookie = some(cookie)
  if r4.get(): dr.text = some(text)
  some(dr)

proc decode(_: typedesc[Message], buf: seq[byte]): Option[Message] =
  var
    msg: Message
    statusOrd: uint
    pbr, pbrr, pbu, pbd, pbdr: ProtoBuffer
  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, statusOrd)
    r2 = pb.getField(2, pbr)
    r3 = pb.getField(3, pbrr)
    r4 = pb.getField(4, pbu)
    r5 = pb.getField(5, pbd)
    r6 = pb.getField(6, pbdr)
  if r1.isErr() or r2.isErr() or r3.isErr() or
     r4.isErr() or r5.isErr() or r6.isErr() or
     not checkedEnumAssign(msg.msgType, statusOrd): return none(Message)
  if r2.get():
    msg.register = Register.decode(pbr.buffer)
    if msg.register.isNone(): return none(Message)
  if r3.get():
    msg.registerResponse = RegisterResponse.decode(pbrr.buffer)
    if msg.registerResponse.isNone(): return none(Message)
  if r4.get():
    msg.unregister = Unregister.decode(pbu.buffer)
    if msg.unregister.isNone(): return none(Message)
  if r5.get():
    msg.discover = Discover.decode(pbd.buffer)
    if msg.discover.isNone(): return none(Message)
  if r6.get():
    msg.discoverResponse = DiscoverResponse.decode(pbdr.buffer)
    if msg.discoverResponse.isNone(): return none(Message)
  some(msg)


type
  RendezVousError* = object of LPError
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

proc checkPeerRecord(spr: seq[byte], peerId: PeerId): Result[void, string] =
  if spr.len == 0: return err("Empty peer record")
  let signedEnv = ? SignedPeerRecord.decode(spr).mapErr(x => $x)
  if signedEnv.data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()

proc sendRegisterResponse(conn: Connection,
                          ttl: uint64) {.async.} =
  let msg = encode(Message(
        msgType: MessageType.RegisterResponse,
        registerResponse: some(RegisterResponse(status: Ok, ttl: some(ttl)))))
  await conn.writeLp(msg.buffer)

proc sendRegisterResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = encode(Message(
        msgType: MessageType.RegisterResponse,
        registerResponse: some(RegisterResponse(status: status, text: some(text)))))
  await conn.writeLp(msg.buffer)

proc sendDiscoverResponse(conn: Connection,
                          s: seq[Register],
                          cookie: Cookie) {.async.} =
  let msg = encode(Message(
        msgType: MessageType.DiscoverResponse,
        discoverResponse: some(DiscoverResponse(
            status: Ok,
            registrations: s,
            cookie: some(cookie.encode().buffer)
          ))
        ))
  await conn.writeLp(msg.buffer)

proc sendDiscoverResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = encode(Message(
        msgType: MessageType.DiscoverResponse,
        discoverResponse: some(DiscoverResponse(status: status, text: some(text)))))
  await conn.writeLp(msg.buffer)

proc countRegister(rdv: RendezVous, peerId: PeerId): int =
  let n = Moment.now()
  for data in rdv.registered:
    if data.peerId == peerId and data.expiration > n:
      result.inc()

proc save(rdv: RendezVous,
          ns: string,
          peerId: PeerId,
          r: Register,
          update: bool = true) =
  let nsSalted = ns & rdv.salt
  discard rdv.namespaces.hasKeyOrPut(nsSalted, newSeq[int]())
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == peerId:
        if update == false: return
        rdv.registered[index].expiration = rdv.defaultDT
    rdv.registered.add(
      RegisteredData(
        peerId: peerId,
        expiration: Moment.now() + r.ttl.get(MinimumTTL).int64.seconds,
        data: r
      )
    )
    rdv.namespaces[nsSalted].add(rdv.registered.high)
#    rdv.registerEvent.fire()
  except KeyError:
    doAssert false, "Should have key"

proc register(rdv: RendezVous, conn: Connection, r: Register): Future[void] =
  trace "Received Register", peerId = conn.peerId, ns = r.ns
  if r.ns.len notin 1..255:
    return conn.sendRegisterResponseError(InvalidNamespace)
  let ttl = r.ttl.get(MinimumTTL)
  if ttl notin MinimumTTL..MaximumTTL:
    return conn.sendRegisterResponseError(InvalidTTL)
  let pr = checkPeerRecord(r.signedPeerRecord, conn.peerId)
  if pr.isErr():
    return conn.sendRegisterResponseError(InvalidSignedPeerRecord, pr.error())
  if rdv.countRegister(conn.peerId) >= RegistrationLimitPerPeer:
    return conn.sendRegisterResponseError(NotAuthorized, "Registration limit reached")
  rdv.save(r.ns, conn.peerId, r)
  conn.sendRegisterResponse(ttl)

proc unregister(rdv: RendezVous, conn: Connection, u: Unregister) =
  trace "Received Unregister", peerId = conn.peerId, ns = u.ns
  let nsSalted = u.ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == conn.peerId:
        rdv.registered[index].expiration = rdv.defaultDT
  except KeyError:
    return

proc discover(rdv: RendezVous, conn: Connection, d: Discover) {.async.} =
  trace "Received Discover", peerId = conn.peerId, ns = d.ns
  if d.ns.len notin 0..255:
    await conn.sendDiscoverResponseError(InvalidNamespace)
    return
  var limit = min(DiscoverLimit, d.limit.get(DiscoverLimit))
  var
    cookie =
      if d.cookie.isSome():
        try:
          Cookie.decode(d.cookie.get()).get()
        except CatchableError:
          await conn.sendDiscoverResponseError(InvalidCookie)
          return
      else: Cookie(offset: rdv.registered.low().uint64 - 1)
  if cookie.ns != d.ns or
      cookie.offset notin rdv.registered.low().uint64..rdv.registered.high().uint64:
    cookie = Cookie(offset: rdv.registered.low().uint64 - 1)
  let
    nsSalted = d.ns & rdv.salt
    namespaces =
      if d.ns != "":
        try:
          rdv.namespaces[nsSalted]
        except KeyError:
          await conn.sendDiscoverResponseError(InvalidNamespace)
          return
      else: toSeq(cookie.offset.int..rdv.registered.high())
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
        if reg.expiration < n or index.uint64 <= cookie.offset: continue
        limit.dec()
        reg.data.ttl = some((reg.expiration - Moment.now()).seconds.uint64)
        reg.data
  rdv.rng.shuffle(s)
  await conn.sendDiscoverResponse(s, Cookie(offset: offset.uint64, ns: d.ns))

proc advertisePeer(rdv: RendezVous,
                   peer: PeerId,
                   msg: seq[byte]) {.async.} =
  proc advertiseWrap() {.async.} =
    try:
      let conn = await rdv.switch.dial(peer, RendezVousCodec)
      defer: await conn.close()
      await conn.writeLp(msg)
      let
        buf = await conn.readLp(4096)
        decodedMsg = Message.decode(buf)

      if decodedMsg.isNone():
        trace "Failed to decode message", peer
        return

      let msgRecv = decodedMsg.get()
      if msgRecv.msgType != MessageType.RegisterResponse:
        trace "Unexpected register response", peer, msgType = msgRecv.msgType
      elif msgRecv.registerResponse.isNone() or
          msgRecv.registerResponse.get().status != ResponseStatus.Ok:
        trace "Refuse to register", peer, response = msgRecv.registerResponse
      
    except CatchableError as exc:
      trace "exception in the advertise", error = exc.msg
    finally:
      rdv.sema.release()
  await rdv.sema.acquire()
  discard await advertiseWrap().withTimeout(5.seconds)

proc advertise*(rdv: RendezVous,
                ns: string,
                ttl: Duration = MinimumDuration) {.async.} =
  let sprBuff = rdv.switch.peerInfo.signedPeerRecord.encode()
  if sprBuff.isErr():
    raise newException(RendezVousError, "Wrong Signed Peer Record")
  if ns.len notin 1..255:
    raise newException(RendezVousError, "Invalid namespace")
  if ttl notin MinimumDuration..MaximumDuration:
    raise newException(RendezVousError, "Invalid time to live")
  let
    r = Register(ns: ns, signedPeerRecord: sprBuff.get(), ttl: some(ttl.seconds.uint64))
    msg = encode(Message(msgType: MessageType.Register, register: some(r)))
  rdv.save(ns, rdv.switch.peerInfo.peerId, r)
  let fut = collect(newSeq()):
    for peer in rdv.peers:
      trace "Send Advertise", peerId = peer, ns
      rdv.advertisePeer(peer, msg.buffer)
  await allFutures(fut)

proc requestLocally*(rdv: RendezVous, ns: string): seq[PeerRecord] =
  let
    nsSalted = ns & rdv.salt
    n = Moment.now()
  try:
    collect(newSeq()):
      for index in rdv.namespaces[nsSalted]:
        if rdv.registered[index].expiration > n:
          SignedPeerRecord.decode(rdv.registered[index].data.signedPeerRecord).get().data
  except KeyError as exc:
    @[]

proc request*(rdv: RendezVous,
              ns: string,
              l: int = DiscoverLimit.int): Future[seq[PeerRecord]] {.async.} =
  let nsSalted = ns & rdv.salt
  var
    s: Table[PeerId, (PeerRecord, Register)]
    limit: uint64
    d = Discover(ns: ns)

  if l <= 0 or l > DiscoverLimit.int:
    raise newException(RendezVousError, "Invalid limit")
  if ns.len notin 0..255:
    raise newException(RendezVousError, "Invalid namespace")
  limit = l.uint64
  proc requestPeer(peer: PeerId) {.async.} =
    let conn = await rdv.switch.dial(peer, RendezVousCodec)
    defer: await conn.close()
    d.limit = some(limit)
    d.cookie =
      try:
        some(rdv.cookiesSaved[peer][ns])
      except KeyError as exc:
        none(seq[byte])
    await conn.writeLp(encode(Message(
      msgType: MessageType.Discover,
      discover: some(d))).buffer)
    let
      buf = await conn.readLp(65536)
      decodedMsg = Message.decode(buf)

    if decodedMsg.isNone():
      trace "Failed to decode message", peer
      return

    let msgRcv = decodedMsg.get()
    if msgRcv.msgType != MessageType.DiscoverResponse or
       msgRcv.discoverResponse.isNone():
      debug "Unexpected discover response", msgType = msgRcv.msgType
      return
    let resp = msgRcv.discoverResponse.get()
    if resp.status != ResponseStatus.Ok:
      trace "Cannot discover", ns, status = resp.status, text = resp.text
      return
    if resp.cookie.isSome() and resp.cookie.get().len < 1000:
      if rdv.cookiesSaved.hasKeyOrPut(peer, {ns: resp.cookie.get()}.toTable):
        rdv.cookiesSaved[peer][ns] = resp.cookie.get()
    for r in resp.registrations:
      if limit == 0: return
      if r.ttl.isNone() or r.ttl.get() > MaximumTTL: continue
      let sprRes = SignedPeerRecord.decode(r.signedPeerRecord)
      if sprRes.isErr(): continue
      let pr = sprRes.get().data
      if s.hasKey(pr.peerId):
        let (prSaved, rSaved) = s[pr.peerId]
        if (prSaved.seqNo == pr.seqNo and rSaved.ttl.get() < r.ttl.get()) or
          prSaved.seqNo < pr.seqNo:
          s[pr.peerId] = (pr, r)
      else:
        s[pr.peerId] = (pr, r)
      limit.dec()
    for (_, r) in s.values():
      rdv.save(ns, peer, r, false)

  # copy to avoid resizes during the loop
  let peers = rdv.peers
  for peer in peers:
    if limit == 0: break
    if RendezVousCodec notin rdv.switch.peerStore[ProtoBook][peer]: continue
    try:
      trace "Send Request", peerId = peer, ns
      await peer.requestPeer()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception catch in request", error = exc.msg
  return toSeq(s.values()).mapIt(it[0])

proc unsubscribeLocally*(rdv: RendezVous, ns: string) =
  let nsSalted = ns & rdv.salt
  try:
    for index in rdv.namespaces[nsSalted]:
      if rdv.registered[index].peerId == rdv.switch.peerInfo.peerId:
        rdv.registered[index].expiration = rdv.defaultDT
  except KeyError:
    return

proc unsubscribe*(rdv: RendezVous, ns: string) {.async.} =
  # TODO: find a way to improve this, maybe something similar to the advertise
  if ns.len notin 1..255:
    raise newException(RendezVousError, "Invalid namespace")
  rdv.unsubscribeLocally(ns)
  let msg = encode(Message(
    msgType: MessageType.Unregister,
    unregister: some(Unregister(ns: ns))))

  proc unsubscribePeer(rdv: RendezVous, peerId: PeerId) {.async.} =
    try:
      let conn = await rdv.switch.dial(peerId, RendezVousCodec)
      defer: await conn.close()
      await conn.writeLp(msg.buffer)
    except CatchableError as exc:
      trace "exception while unsubscribing", error = exc.msg

  for peer in rdv.peers:
    discard await rdv.unsubscribePeer(peer).withTimeout(5.seconds)

proc setup*(rdv: RendezVous, switch: Switch) =
  rdv.switch = switch
  proc handlePeer(peerId: PeerId, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      rdv.peers.add(peerId)
    elif event.kind == PeerEventKind.Left:
      rdv.peers.keepItIf(it != peerId)
  rdv.switch.addPeerEventHandler(handlePeer, Joined)
  rdv.switch.addPeerEventHandler(handlePeer, Left)

proc new*(T: typedesc[RendezVous],
          rng: ref HmacDrbgContext = newRng()): T =
  let rdv = T(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](1),
    defaultDT: Moment.now() - 1.days,
    #registerEvent: newAsyncEvent(),
    sema: newAsyncSemaphore(SemaphoreDefaultSize)
  )
  logScope: topics = "libp2p discovery rendezvous"
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let
        buf = await conn.readLp(4096)
        decodedMsg = Message.decode(buf)

      if decodedMsg.isNone():
        trace "Failed to decode message"
        return

      let msg = decodedMsg.get()
      case msg.msgType:
        of MessageType.Register: await rdv.register(conn, msg.register.get())
        of MessageType.RegisterResponse:
          trace "Got an unexpected Register Response", response = msg.registerResponse
        of MessageType.Unregister: rdv.unregister(conn, msg.unregister.get())
        of MessageType.Discover: await rdv.discover(conn, msg.discover.get())
        of MessageType.DiscoverResponse:
          trace "Got an unexpected Discover Response", response = msg.discoverResponse
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", error = exc.msg
    finally:
      await conn.close()

  rdv.handler = handleStream
  rdv.codec = RendezVousCodec
  return rdv

proc new*(T: typedesc[RendezVous],
         switch: Switch,
         rng: ref HmacDrbgContext = newRng()): T =
  let rdv = T.new(rng)
  rdv.setup(switch)
  return rdv

proc deletesRegister(rdv: RendezVous) {.async.} =
  heartbeat "Register timeout", 1.minutes:
    let n = Moment.now()
    rdv.registered.flushIfIt(it.expiration < n)
    for data in rdv.namespaces.mvalues():
      data.keepItIf(it >= rdv.registered.offset)

method start*(rdv: RendezVous) {.async.} =
  if not rdv.registerDeletionLoop.isNil:
    warn "Starting rendezvous twice"
    return
  rdv.registerDeletionLoop = rdv.deletesRegister()
  rdv.started = true

method stop*(rdv: RendezVous) {.async.} =
  if rdv.registerDeletionLoop.isNil:
    warn "Stopping rendezvous without starting it"
    return
  rdv.started = false
  rdv.registerDeletionLoop.cancel()
  rdv.registerDeletionLoop = nil

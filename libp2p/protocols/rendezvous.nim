# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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
       stew/[byteutils, objects],
       protobuf_serialization
import ./protocol,
       ../switch,
       ../routing_record,
       ../utils/heartbeat,
       ../stream/connection,
       ../utils/offsettedseq,
       ../utils/semaphore

export chronicles, protobuf_serialization

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

const
  RdvRegister = 0'u32
  RdvRegisterResponse = 1'u32
  RdvUnregister = 2'u32
  RdvDiscover = 3'u32
  RdvDiscoverResponse = 4'u32
  ResponseOk = 0'u32
  ResponseInvalidNamespace = 100'u32
  ResponseInvalidSignedPeerRecord = 101'u32
  ResponseInvalidTTL = 102'u32
  ResponseInvalidCookie = 103'u32
  ResponseNotAuthorized = 200'u32
  ResponseInternalError = 300'u32
  ResponseUnavailable = 400'u32

type
  Cookie {.proto3.} = object
    offset {.fieldNumber: 1, pint.}: uint64
    ns {.fieldNumber: 2.}: string

  Register {.proto3.} = object
    ns {.fieldNumber: 1.}: string
    signedPeerRecord {.fieldNumber: 2.}: seq[byte]
    ttl {.fieldNumber: 3, pint.}: uint64 # in seconds

  RegisterResponse {.proto3.} = object
    status {.fieldNumber: 1, pint.}: uint64
    text {.fieldNumber: 2.}: string
    ttl {.fieldNumber: 3, pint.}: uint64 # in seconds

  Unregister {.proto3.} = object
    ns {.fieldNumber: 1.}: string

  Discover {.proto3.} = object
    ns {.fieldNumber: 1.}: string
    limit {.fieldNumber: 2, pint.}: uint64
    cookie {.fieldNumber: 3.}: seq[byte]

  DiscoverResponse {.proto3.} = object
    registrations {.fieldNumber: 1.}: seq[Register]
    cookie {.fieldNumber: 2.}: seq[byte]
    status {.fieldNumber: 3, pint.}: uint64
    text {.fieldNumber: 4.}: string

  Message {.proto3.} = object
    msgType {.fieldNumber: 1, pint.}: uint64
    register {.fieldNumber: 2.}: Register
    registerResponse {.fieldNumber: 3.}: RegisterResponse
    unregister {.fieldNumber: 4.}: Unregister
    discover {.fieldNumber: 5.}: Discover
    discoverResponse {.fieldNumber: 6.}: DiscoverResponse

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
  let msg = Protobuf.encode(Message(
        msgType: RdvRegisterResponse,
        registerResponse: RegisterResponse(status: ResponseOk, ttl: ttl)))
  await conn.writeLp(msg)

proc sendRegisterResponseError(conn: Connection,
                               status: uint64,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: RdvRegisterResponse,
        registerResponse: RegisterResponse(status: status, text: text)))
  await conn.writeLp(msg)

proc sendDiscoverResponse(conn: Connection,
                          s: seq[Register],
                          cookie: Cookie) {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: RdvDiscoverResponse,
        discoverResponse: DiscoverResponse(
            status: ResponseOk,
            registrations: s,
            cookie: Protobuf.encode(cookie)
          )
        ))
  await conn.writeLp(msg)

proc sendDiscoverResponseError(conn: Connection,
                               status: uint64,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: RdvDiscoverResponse,
        discoverResponse: DiscoverResponse(status: status, text: text)))
  await conn.writeLp(msg)

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
        expiration: Moment.now() + max(r.ttl, MinimumTTL).int64.seconds,
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
    return conn.sendRegisterResponseError(ResponseInvalidNamespace)
  let ttl = max(r.ttl, MinimumTTL)
  if ttl notin MinimumTTL..MaximumTTL:
    return conn.sendRegisterResponseError(ResponseInvalidTTL)
  let pr = checkPeerRecord(r.signedPeerRecord, conn.peerId)
  if pr.isErr():
    return conn.sendRegisterResponseError(ResponseInvalidSignedPeerRecord, pr.error())
  if rdv.countRegister(conn.peerId) >= RegistrationLimitPerPeer:
    return conn.sendRegisterResponseError(ResponseNotAuthorized, "Registration limit reached")
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
    await conn.sendDiscoverResponseError(ResponseInvalidNamespace)
    return
  var limit = min(d.limit ,DiscoverLimit)
  var
    cookie =
      if d.cookie != @[]:
        try:
          Protobuf.decode(d.cookie, Cookie)
        except CatchableError:
          await conn.sendDiscoverResponseError(ResponseInvalidCookie)
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
          await conn.sendDiscoverResponseError(ResponseInvalidNamespace)
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
        reg.data.ttl = (reg.expiration - Moment.now()).seconds.uint64
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
        msgRecv = Protobuf.decode(buf, Message)
      if msgRecv.msgType != RdvRegisterResponse:
        trace "Unexpected register response", peer, msgType = msgRecv.msgType
      elif msgRecv.registerResponse.status != ResponseOk:
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
    r = Register(ns: ns, signedPeerRecord: sprBuff.get(), ttl: ttl.seconds.uint64)
    msg = Protobuf.encode(Message(msgType: RdvRegister, register: r))
  rdv.save(ns, rdv.switch.peerInfo.peerId, r)
  let fut = collect(newSeq()):
    for peer in rdv.peers:
      trace "Send Advertise", peerId = peer, ns
      rdv.advertisePeer(peer, msg)
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
    d.limit = limit
    d.cookie =
      try:
        rdv.cookiesSaved[peer][ns]
      except KeyError as exc:
        @[]
    await conn.writeLp(Protobuf.encode(Message(
      msgType: RdvDiscover,
      discover: d)))
    let
      buf = await conn.readLp(65536)
      msgRcv = Protobuf.decode(buf, Message)
    if msgRcv.msgType != RdvDiscoverResponse:
      debug "Unexpected discover response", msgType = msgRcv.msgType
      return
    let resp = msgRcv.discoverResponse
    if resp.status != ResponseOk:
      trace "Cannot discover", ns, status = resp.status, text = resp.text
      return
    if resp.cookie.len < 1000:
      if rdv.cookiesSaved.hasKeyOrPut(peer, {ns: resp.cookie}.toTable):
        rdv.cookiesSaved[peer][ns] = resp.cookie
    for r in resp.registrations:
      if limit == 0: return
      if r.ttl > MaximumTTL: continue
      let sprRes = SignedPeerRecord.decode(r.signedPeerRecord)
      if sprRes.isErr(): continue
      let pr = sprRes.get().data
      if s.hasKey(pr.peerId):
        let (prSaved, rSaved) = s[pr.peerId]
        if (prSaved.seqNo == pr.seqNo and rSaved.ttl < r.ttl) or
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
  let msg = Protobuf.encode(Message(
    msgType: RdvUnregister,
    unregister: Unregister(ns: ns)))

  proc unsubscribePeer(rdv: RendezVous, peerId: PeerId) {.async.} =
    try:
      let conn = await rdv.switch.dial(peerId, RendezVousCodec)
      defer: await conn.close()
      await conn.writeLp(msg)
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
        msg = Protobuf.decode(buf, Message)
      case msg.msgType:
        of RdvRegister: await rdv.register(conn, msg.register)
        of RdvRegisterResponse:
          trace "Got an unexpected Register Response", response = msg.registerResponse
        of RdvUnregister: rdv.unregister(conn, msg.unregister)
        of RdvDiscover: await rdv.discover(conn, msg.discover)
        of RdvDiscoverResponse:
          trace "Got an unexpected Discover Response", response = msg.discoverResponse
        else:
          trace "Got an unexpected message type", msgtype = msg.msgType
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

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

import tables, sequtils, sugar, sets
import chronos, chronicles, protobuf_serialization, bearssl/rand
import ./discoveryinterface,
       ../protocol,
       ../../switch,
       ../../routing_record,
       ../../utils/heartbeat,
       ../../stream/connection,
       ../../utils/offsettedseq,
       ../../utils/semaphore

export chronicles, protobuf_serialization
logScope:
  topics = "libp2p discovery rendezvous"

const
  RendezVousCodec* = "/rendezvous/1.0.0"
  MinimumTTL = 2'u64 * 60 * 60
  MaximumTTL = 72'u64 * 60 * 60
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

  Cookie {.protobuf3.} = object
    offset {.pint, fieldNumber: 1.}: uint64
    ns {.fieldNumber: 2.}: string

  Register {.protobuf3.} = object
    ns {.fieldNumber: 1.}: string
    signedPeerRecord {.fieldNumber: 2.}: seq[byte]
    ttl {.pint, fieldNumber: 3.}: Option[uint64] # in seconds

  RegisterResponse {.protobuf3.} = object
    status {.fieldNumber: 1.}: ResponseStatus
    text {.fieldNumber: 2.}: Option[string]
    ttl {.pint, fieldNumber: 3.}: Option[uint64] # in seconds

  Unregister {.protobuf3.} = object
    ns {.fieldNumber: 1.}: string

  Discover {.protobuf3.} = object
    ns {.fieldNumber: 1.}: string
    limit {.pint, fieldNumber: 2.}: Option[uint64]
    cookie {.fieldNumber: 3.}: Option[seq[byte]]

  DiscoverResponse {.protobuf3.} = object
    registrations {.fieldNumber: 1.}: seq[Register]
    cookie {.fieldNumber: 2.}: Option[seq[byte]]
    status {.fieldNumber: 3.}: ResponseStatus
    text {.fieldNumber: 4.}: Option[string]

  Message {.protobuf3.} = object
    msgType {.fieldNumber: 1.}: MessageType
    register {.fieldNumber: 2.}: Option[Register]
    registerResponse {.fieldNumber: 3.}: Option[RegisterResponse]
    unregister {.fieldNumber: 4.}: Option[Unregister]
    discover {.fieldNumber: 5.}: Option[Discover]
    discoverResponse {.fieldNumber: 6.}: Option[DiscoverResponse]

  RegisteredData = object
    expiration: Moment
    peerId: PeerId
    data: Register

  RegisteredSeq = object
    s: seq[RegisteredData]
    offset: uint64

  RendezVous* = ref object of LPProtocol
    indexes: Table[string, OffsettedSeq[int]]
    registered: OffsettedSeq[RegisteredData]
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
        msgType: MessageType.RegisterResponse,
        registerResponse: some(RegisterResponse(status: Ok, ttl: some(ttl)))))
  await conn.writeLp(msg)

proc sendRegisterResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: MessageType.RegisterResponse,
        registerResponse: some(RegisterResponse(status: status, text: some(text)))))
  await conn.writeLp(msg)

proc sendDiscoverResponse(conn: Connection,
                          s: seq[Register],
                          cookie: Cookie) {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: MessageType.DiscoverResponse,
        discoverResponse: some(DiscoverResponse(
            status: Ok,
            registrations: s,
            cookie: some(Protobuf.encode(cookie))
          ))
        ))
  await conn.writeLp(msg)

proc sendDiscoverResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: MessageType.DiscoverResponse,
        discoverResponse: some(DiscoverResponse(status: status, text: some(text)))))
  await conn.writeLp(msg)

proc countRegister(rdv: RendezVous, peerId: PeerId): int =
   for data in rdv.registered:
     if data.peerId == peerId:
       result.inc()

proc save(rdv: RendezVous,
          ns: string,
          peerId: PeerId,
          r: Register,
          update: bool = true) =
  let nsSalted = ns & rdv.salt
  discard rdv.indexes.hasKeyOrPut(nsSalted, initOffsettedSeq[int]())
  try:
    for index in rdv.indexes[nsSalted]:
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
    rdv.indexes[nsSalted].add(rdv.registered.high)
#    rdv.registerEvent.fire()
  except KeyError:
    doAssert false, "Should have key"

proc register(rdv: RendezVous, conn: Connection, r: Register): Future[void] =
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
  let nsSalted = u.ns & rdv.salt
  try:
    for index in rdv.indexes[nsSalted]:
      if rdv.registered[index].peerId == conn.peerId:
        rdv.registered[index].expiration = rdv.defaultDT
  except KeyError:
    return

proc discover(rdv: RendezVous, conn: Connection, d: Discover): Future[void] =
  if d.ns.len notin 0..255:
    return conn.sendDiscoverResponseError(InvalidNamespace)
  var limit = min(DiscoverLimit, d.limit.get(DiscoverLimit))
  let
    nsSalted = d.ns & rdv.salt
    cookie =
      if d.cookie.isSome():
        try: Protobuf.decode(d.cookie.get(), type(Cookie))
        except ProtobufReadError: return conn.sendDiscoverResponseError(InvalidCookie)
      else: Cookie(offset: rdv.registered.low().uint64, ns: d.ns)
    indexes =
      if d.ns != "":
        try: rdv.indexes[nsSalted].s
        except KeyError: return conn.sendDiscoverResponseError(InvalidNamespace)
      else: toSeq(rdv.registered.low()..rdv.registered.high())
  if indexes.len() == 0:
    return conn.sendDiscoverResponse(@[], Cookie())
  var offset = indexes[^1]
  let s = collect(newSeq()):
      for index in indexes:
        var reg = rdv.registered[index]
        if index.uint64 < cookie.offset: continue
        if limit == 0:
          offset = index
          break
        limit.dec()
        reg.data.ttl = some((reg.expiration - Moment.now()).seconds.uint64)
        reg.data
  conn.sendDiscoverResponse(s, Cookie(offset: offset.uint64, ns: d.ns))

proc advertisePeer(rdv: RendezVous, peer: PeerId, msg: seq[byte]) {.async.} =
  proc advertiseWrap() {.async.} =
    try:
      let conn = await rdv.switch.dial(peer, RendezVousCodec)
      defer: await conn.close()
      await conn.writeLp(msg)
      let
        buf = await conn.readLp(4096)
        msgRecv = Protobuf.decode(buf, type(Message))
      if msgRecv.msgType != MessageType.RegisterResponse:
        trace "Unexpected register response", peer, msgType = msgRecv.msgType
      elif msgRecv.registerResponse.isNone() or
           msgRecv.registerResponse.get().status != ResponseStatus.Ok:
        trace "Refuse to register", peer, response = msgRecv.registerResponse
    except CatchableError as exc:
      trace "exception in the advertise", error = exc.msg
    finally:
      rdv.sema.release()
  discard await advertiseWrap().withTimeout(5.seconds)

proc advertise*(rdv: RendezVous,
                ns: string,
                ttl: uint64 = MinimumTTL) {.async.} =
  let sprBuff = rdv.switch.peerInfo.signedPeerRecord.encode()
  if sprBuff.isErr() or ns.len notin 1..255 or ttl notin MinimumTTL..MaximumTTL:
    return
  let
    r = Register(ns: ns, signedPeerRecord: sprBuff.get(), ttl: some(ttl))
    msg = Protobuf.encode(Message(msgType: MessageType.Register, register: some(r)))
  rdv.save(ns, rdv.switch.peerInfo.peerId, r)
  for peer in rdv.peers:
    await rdv.sema.acquire()
    asyncSpawn rdv.advertisePeer(peer, msg)

proc requestLocally*(rdv: RendezVous, ns: string): seq[PeerRecord] =
  let nsSalted = ns & rdv.salt
  try:
    collect(newSeq()):
      for index in rdv.indexes[nsSalted]:
        SignedPeerRecord.decode(rdv.registered[index].data.signedPeerRecord).get().data
  except KeyError as exc:
    @[]

proc request*(rdv: RendezVous, ns: string): Future[seq[PeerRecord]] {.async.} =
  let nsSalted = ns & rdv.salt
  var
    s: seq[PeerRecord]
    limit = DiscoverLimit
    d = Discover(ns: ns)

  proc requestPeer(peer: PeerId) {.async.} =
    let conn = await rdv.switch.dial(peer, RendezVousCodec)
    defer: await conn.close()
    d.limit = some(limit)
    d.cookie =
      try:
        some(rdv.cookiesSaved[peer][ns])
      except KeyError as exc:
        none(seq[byte])
    await conn.writeLp(Protobuf.encode(Message(
      msgType: MessageType.Discover,
      discover: some(d))))
    let
      buf = await conn.readLp(65536)
      msgRcv = Protobuf.decode(buf, type(Message))
    if msgRcv.msgType != MessageType.DiscoverResponse or
       msgRcv.discoverResponse.isNone():
      trace "Unexpected discover response", msgType = msgRcv.msgType
      return
    let resp = msgRcv.discoverResponse.get()
    if resp.status != ResponseStatus.Ok:
      trace "Refuse to discover", status = resp.status, text = resp.text
      return
    if resp.cookie.isSome():
      if rdv.cookiesSaved.hasKeyOrPut(peer, {ns: resp.cookie.get()}.toTable):
        rdv.cookiesSaved[peer][ns] = resp.cookie.get()
    for r in resp.registrations:
      if limit == 0: return
      let sprRes = SignedPeerRecord.decode(r.signedPeerRecord)
      if sprRes.isErr(): continue
      let pr = sprRes.get().data
      if s.anyIt(it.peerId == pr.peerId): continue
      limit.dec()
      rdv.save(ns, peer, r, false)
      s.add(pr)

  for peer in rdv.peers:
    if limit == 0: break
    try:
      await peer.requestPeer()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception catch in request", error = exc.msg
  return s

proc new*(T: typedesc[RendezVous],
          switch: Switch,
          semSize: int = SemaphoreDefaultSize,
          rng: ref HmacDrbgContext = newRng()): T =
  let rdv = T(
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](),
    switch: switch,
    defaultDT: Moment.now() - 1.days,
    #registerEvent: newAsyncEvent(),
    sema: newAsyncSemaphore(semSize)
  )

  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      discard
      let
        buf = await conn.readLp(4096)
        msg = Protobuf.decode(buf, type(Message))
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

  proc handlePeer(peerId: PeerId, event: PeerEvent): Future[void] =
    if RendezVousCodec in switch.peerStore[ProtoBook][peerId]:
      if event.kind == PeerEventKind.Joined: rdv.peers.add(peerId)
      elif event.kind == PeerEventKind.Left: rdv.peers.keepItIf(it != peerId)

  rdv.switch.addPeerEventHandler(handlePeer, PeerEventKind.Joined)
  rdv.switch.addPeerEventHandler(handlePeer, PeerEventKind.Left)

  rdv.handler = handleStream
  rdv.codec = RendezVousCodec
  return rdv

proc deletesRegister(rdv: RendezVous) {.async.} =
  # TODO replace 1 minutes by the shortest time to sleep before a registration finished
  heartbeat "Register timeout", 1.minutes:
    let n = Moment.now()
    rdv.registered.flushIfIt(it.expiration < n)
    for data in rdv.indexes.mvalues():
      data.flushIfIt(it < rdv.registered.offset)

method start*(rdv: RendezVous) {.async.} =
  if not rdv.registerDeletionLoop.isNil:
    warn "Starting rendezvous twice"
  rdv.registerDeletionLoop = rdv.deletesRegister()
  rdv.started = true

method stop*(rdv: RendezVous) {.async.} =
  if rdv.registerDeletionLoop.isNil:
    warn "Stopping rendezvous without starting it"
  rdv.started = false
  rdv.registerDeletionLoop.cancel()
  rdv.registerDeletionLoop = nil

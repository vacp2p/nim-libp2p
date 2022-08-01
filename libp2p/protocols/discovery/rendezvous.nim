# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [Defect].}

import tables, times, sequtils, sugar, sets
import chronos, chronicles, protobuf_serialization, bearssl/rand
import ./discoveryinterface,
       ../protocol,
       ../../switch,
       ../../routing_record,
       ../../utils/heartbeat,
       ../../stream/connection,
       ../../utils/offsettedseq

logScope:
  topics = "libp2p discovery rendezvous"

const
  RendezVousCodec* = "/rendezvous/1.0.0"
  MinimumTTL = 2'u64 * 60 * 60
  MaximumTTL = 72'u64 * 60 * 60
  RegistrationLimitPerPeer = 1000
  DiscoverLimit = 1000'u64

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
    ns {.fieldNumber: 1.}: Option[string]
    signedPeerRecord {.fieldNumber: 2.}: Option[seq[byte]]
    ttl {.pint, fieldNumber: 3.}: Option[uint64] # in seconds

  RegisterResponse {.protobuf3.} = object
    status {.fieldNumber: 1.}: Option[ResponseStatus]
    text {.fieldNumber: 2.}: Option[string]
    ttl {.pint, fieldNumber: 3.}: Option[uint64] # in seconds

  Unregister {.protobuf3.} = object
    ns {.fieldNumber: 1.}: Option[string]

  Discover {.protobuf3.} = object
    ns {.fieldNumber: 1.}: Option[string]
    limit {.pint, fieldNumber: 2.}: Option[uint64]
    cookie {.fieldNumber: 3.}: Option[seq[byte]]

  DiscoverResponse {.protobuf3.} = object
    registrations {.fieldNumber: 1.}: seq[Register]
    cookie {.fieldNumber: 2.}: Option[seq[byte]]
    status {.fieldNumber: 3.}: Option[ResponseStatus]
    text {.fieldNumber: 4.}: Option[string]

  Message {.protobuf3.} = object
    msgType {.fieldNumber: 1.}: Option[MessageType]
    register {.fieldNumber: 2.}: Option[Register]
    registerResponse {.fieldNumber: 3.}: Option[RegisterResponse]
    unregister {.fieldNumber: 4.}: Option[Unregister]
    discover {.fieldNumber: 5.}: Option[Discover]
    discoverResponse {.fieldNumber: 6.}: Option[DiscoverResponse]

  RegisteredData = object
    expireDate: DateTime
    peerId: PeerID
    data: Register

  RegisteredSeq = object
    s: seq[RegisteredData]
    offset: uint64

  RendezVous* = ref object of LPProtocol
    indexes: Table[string, OffsettedSeq[int]]
    registered: OffsettedSeq[RegisteredData]
    salt: string
    defaultDT: DateTime
    registerDeletionLoop: Future[void]
    registerEvent: AsyncEvent
    peers: seq[PeerId]
    switch: Switch

proc checkPeerRecord(spr: Option[seq[byte]], peerId: PeerId): Result[void, string] =
  if spr.isNone():
    return err("Empty peer record")
  let signedEnv = SignedPeerRecord.decode(spr.get())
  if signedEnv.isErr():
    return err($signedEnv.error())
  if signedEnv.get().data.peerId != peerId:
    return err("Bad Peer ID")
  return ok()

proc sendRegisterResponse(conn: Connection,
                          ttl: uint64) {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: some(MessageType.RegisterResponse),
        registerResponse: some(RegisterResponse(status: some(Ok), ttl: some(ttl)))))
  await conn.writeLP(msg)

proc sendRegisterResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: some(MessageType.RegisterResponse),
        registerResponse: some(RegisterResponse(status: some(status), text: some(text)))))
  await conn.writeLP(msg)

proc sendDiscoverResponse(conn: Connection,
                          s: seq[Register],
                          cookie: Cookie) {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: some(MessageType.DiscoverResponse),
        discoverResponse: some(DiscoverResponse(
            status: some(Ok),
            registrations: s,
            cookie: some(Protobuf.encode(cookie))
          ))
        ))
  await conn.writeLP(msg)

proc sendDiscoverResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(Message(
        msgType: some(MessageType.DiscoverResponse),
        discoverResponse: some(DiscoverResponse(status: some(status), text: some(text)))))
  await conn.writeLP(msg)

proc countRegister(rdv: RendezVous, peerId: PeerID): int =
   for data in rdv.registered:
     if data.peerId == peerId:
       result.inc()

proc save(rdv: RendezVous, ns: string, peerId: PeerId, r: Register, ttl: uint64 = MinimumTTL) =
  let
    n = now()
    nsSalted = ns & rdv.salt
  discard rdv.indexes.hasKeyOrPut(nsSalted, initOffsettedSeq[int]())
  try:
    for index in rdv.indexes[nsSalted]:
      if rdv.registered[index].peerId == peerId:
        rdv.registered[index].expireDate = rdv.defaultDT
    rdv.registered.add(
      RegisteredData(
        peerId: peerId,
        expireDate: now() + initDuration(ttl.int64),
        data: r
      )
    )
    rdv.indexes[nsSalted].add(rdv.registered.high)
#    rdv.registerEvent.fire()
  except KeyError:
    doAssert false, "Should have key"

proc register(rdv: RendezVous, conn: Connection, r: Register): Future[void] =
  let ns = r.ns.get("")
  if ns.len notin 1..255:
    return conn.sendRegisterResponseError(InvalidNamespace)
  let ttl = r.ttl.get(MinimumTTL)
  if ttl notin MinimumTTL..MaximumTTL:
    return conn.sendRegisterResponseError(InvalidTTL)
  let pr = checkPeerRecord(r.signedPeerRecord, conn.peerId)
  if pr.isErr():
    return conn.sendRegisterResponseError(InvalidSignedPeerRecord, pr.error())
  if rdv.countRegister(conn.peerId) >= RegistrationLimitPerPeer:
    return conn.sendRegisterResponseError(NotAuthorized, "Registration limit reached")
  rdv.save(ns, conn.peerId, r, ttl)
  conn.sendRegisterResponse(ttl)

proc unregister(rdv: RendezVous, conn: Connection, u: Unregister) =
  let nsSalted = u.ns.get("") & rdv.salt
  try:
    for index in rdv.indexes[nsSalted]:
      if rdv.registered[index].peerId == conn.peerId:
        rdv.registered[index].expireDate = rdv.defaultDT
  except KeyError:
    return

proc discover(rdv: RendezVous, conn: Connection, d: Discover): Future[void] =
  let ns = d.ns.get("")
  if ns.len notin 0..255:
    return conn.sendDiscoverResponseError(InvalidNamespace)
  var
    limit = min(DiscoverLimit, d.limit.get(DiscoverLimit))
  let
    nsSalted = ns & rdv.salt
    cookie = if d.cookie.isSome():
      try: Protobuf.decode(d.cookie.get(), type(Cookie))
      except ProtobufReadError: return conn.sendDiscoverResponseError(InvalidCookie)
    else: Cookie(offset: rdv.registered.low().uint64, ns: ns)
    indexes = if ns != "":
        try: rdv.indexes[nsSalted].s
        except KeyError: return conn.sendDiscoverResponseError(InvalidNamespace)
      else: toSeq(rdv.registered.low()..rdv.registered.high())
  if indexes.len() == 0:
    return conn.sendDiscoverResponse(@[], Cookie())
  var offset = indexes[^1]
  let s = collect(newSeq()):
      for index in indexes:
        if index.uint64 < cookie.offset: continue
        if limit == 0:
          offset = index
          break
        limit.dec()
        rdv.registered[index].data
  conn.sendDiscoverResponse(s, Cookie(offset: offset.uint64, ns: ns))

proc advertise*(rdv: RendezVous,
                ns: string,
                ttl: uint64 = MinimumTTL) {.async.} =
  let sprBuff = rdv.switch.peerInfo.signedPeerRecord.envelope.encode()
  if sprBuff.isErr() or ns.len() notin 1..255 or ttl notin MinimumTTL..MaximumTTL:
    return
  let r = Register(ns: some(ns), signedPeerRecord: some(sprBuff), ttl: some(ttl))
  rdv.save(ns, rdv.switch.peerInfo.peerId, ttl)
  # send to peers

proc new*(T: typedesc[RendezVous],
          switch: Switch,
          rng: ref HmacDrbgContext = newRng()): T =
  result = T(
    salt: string.fromBytes(generateBytes(rng, 8)),
    registered: initOffsettedSeq[RegisteredData](),
    defaultDT: 0.fromUnix().utc(),
    switch: switch,
    registerEvent: newAsyncEvent()
  )

  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msg = await conn.readLp(4096)
      case msg.msgType.get():
        of Register: await result.register(conn, msg.register.get())
        of RegisterResponse:
          trace "Got an unexpected Register Response", response = msg.registerResponse
        of Unregister: result.unregister(conn, msg.unregister.get())
        of Discover: await result.discover(conn, msg.discover.get())
        of DiscoverResponse:
          trace "Got an unexpected Discover Response", response = msg.discoverResponse
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", error = exc.msg
    finally:
      conn.close()

  proc handlePeer(peerId: PeerId, kind: PeerEventKind) =
    if RendezVousCodec in switch.peerStore[ProtoBook][peerId]:
      if kind == PeerEventKind.Joined: rdv.peers.add(peerId)
      elif kind == PeerEventKind.Left: rdv.peers.keepItIf(it != peerId)

  result.switch.addPeerEventHandler(handlePeer, PeerEventKind.Joined)
  result.switch.addPeerEventHandler(handlePeer, PeerEventKind.Left)

  result.handler = handleStream
  result.codec = RendezVousCodec

proc deletesRegister(rdv: RendezVous) {.async.} =
  heartbeat "Register timeout", chronos.minutes(1):
    let n = now()
    rdv.registered.flushIfIt(it.expireDate < n)
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

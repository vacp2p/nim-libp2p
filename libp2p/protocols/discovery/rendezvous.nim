# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## The switch is the core of libp2p, which brings together the
## transports, the connection manager, the upgrader and other
## parts to allow programs to use libp2p

{.push raises: [Defect].}

import tables, times, sequtils
import chronos, chronicles, protobuf_serialization, bearssl/rand
import ./discoveryinterface,
       ../../routing_record,
       ../../stream/connection

logScope:
  topics = "libp2p discovery rendezvous"

const
  RendezVousCodec* = "/rendezvous/1.0.0"
  MinimumTTL = 2'u64 * 60 * 60
  MaximumTTL = 72'u64 * 60 * 60
  RegistrationLimitPerPeer = 1000

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
    timestamp {.pint, fieldNumber: 1.}: int64
    topic {.fieldNumber: 2.}: string

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
    limit {.pint, fieldNumber: 3.}: Option[uint64]
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
    ttl: DateTime
    registeredTime: DateTime
    data: Register

  RendezVous* = ref object of DiscoveryInterface
    register: Table[string, Table[PeerID, RegisteredData]]
    salt: string
    rng: ref HmacDrbgContext

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
  let msg = Protobuf.encode(RegisterResponse(status: some(Ok), ttl: some(ttl)))
  await conn.writeLP(msg)

proc sendRegisterResponseError(conn: Connection,
                               status: ResponseStatus,
                               text: string = "") {.async.} =
  let msg = Protobuf.encode(RegisterResponse(status: some(status), text: some(text)))
  await conn.writeLP(msg)

proc countRegister(rdv: RendezVous, peerId: PeerID): int =
  for r in rdv.register.values():
    for pid in r.keys():
      if pid == peerId: result.inc()

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
  let
    n = now()
    nsSalted = ns & rdv.salt
  discard rdv.register.hasKeyOrPut(nsSalted, initTable[PeerID, RegisteredData]())
  try:
    discard rdv.register[nsSalted].hasKeyOrPut(conn.peerId, RegisteredData(registeredTime: n))
    rdv.register[nsSalted][conn.peerId].ttl = n + initDuration(ttl.int64)
    rdv.register[nsSalted][conn.peerId].data = r
  except:
    doAssert false, "Should have key"
  conn.sendRegisterResponse(ttl)

proc unregister(rdv: RendezVous, conn: Connection, u: Unregister) {.async.} = discard

proc discover(rdv: RendezVous, conn: Connection, d: Discover) {.async.} = discard

proc new*(T: typedesc[RendezVous], rng: ref HmacDrbgContext = newRng()): T =
  result = T(rng: rng)
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msg = await conn.readLp(4096)
      case msg.msgType.get():
        of Register: await result.register(conn, msg.register.get())
        of RegisterResponse:
          trace "Got an unexpected Register Response", response = msg.registerResponse
        of Unregister: await result.unregister(conn, msg.unregister.get())
        of Discover: await result.discover(conn, msg.discover.get())
        of DiscoverResponse:
          trace "Got an unexpected Discover Response", response = msg.discoverResponse
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in rendezvous handler", error = exc.msg
    finally:
      conn.close()
  result.handler = handleStream
  result.codec = RendezVousCodec
  result.register = initTable[string, Table[PeerID, RegisteredData]]()
  result.salt = string.fromBytes(generateBytes(rng, 8))

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/hashes
import chronos
import ../../protobuf/minprotobuf
import ../../varint
import ../../utils/opt
import results
import ../../multiaddress
import stew/[endians2, objects]
import ../../crypto/crypto
import protobuf_serialization
import protobuf_serialization/pkg/results
import protobuf_serialization/std/enums
import ../../utils/protobuf

type
  Record* = object
    key*: seq[byte]
    value*: Opt[seq[byte]]
    timeReceived*: Opt[string]

  MessageType* = enum
    putValue = 0
    getValue = 1
    addProvider = 2
    getProviders = 3
    findNode = 4
    ping = 5 # Deprecated
    register = 16 # REGISTER for Service Discovery
    getAds = 17 # GET_ADS for Service Discovery

  ConnectionStatus* = enum
    notConnected = 0
    connected = 1
    canConnect = 2 # Unused
    cannotConnect = 3 # Unused

  Peer* = object
    id*: seq[byte]
    addrs*: seq[MultiAddress]
    connection*: ConnectionStatus

  # Registration status for Service Discovery
  RegistrationStatus* = enum
    Confirmed = 0
    Wait = 1
    Rejected = 2

  AddProviderStatus* = enum
    ## Response status carried in field 11 of an ADD_PROVIDER reply (nim extension).
    ## Only populated when the responding peer has ``providerRejection = true``.
    ## Peers with ``providerRejection = false`` never write this field; receivers
    ## always decode it when present and act on it only if their own
    ## ``providerRejection`` is true.
    accepted = 0
    rejected = 1

  # Ticket message for Service Discovery
  # Nested within Register message
  Ticket* = object
    advertisement*: seq[byte] # field 1 - Copy of the original advertisement
    tInit*: Moment # field 2 - Ticket creation timestamp (Unix time in seconds)
    tMod*: Moment # field 3 - Last modification timestamp (Unix time in seconds)
    tWaitFor*: Duration # field 4 - Remaining wait time in seconds
    signature*: seq[byte] # field 5 - Ed25519 signature

  TicketMsg {.proto2.} = object
    advertisement {.fieldNumber: 1, required.}: seq[byte]
    tInit {.fieldNumber: 2, pint, required.}: uint64
    tMod {.fieldNumber: 3, pint, required.}: uint64
    tWaitFor {.fieldNumber: 4, pint, required.}: uint32
    signature {.fieldNumber: 5.}: Opt[seq[byte]]

  # Register message for Service Discovery
  # Field 21 in the main Message
  RegisterMessage* {.proto2.} = object
    advertisement* {.fieldNumber: 1, required.}: seq[byte] # field 1 - Encoded advertisement
    status* {.fieldNumber: 2, ext.}: Opt[RegistrationStatus] # field 2 - Registration status (response only)
    ticket* {.fieldNumber: 3, ext.}: Opt[Ticket] # field 3 - Optional ticket

  # GetAds message for Service Discovery
  # Field 22 in the main Message
  GetAdsMessage* {.proto2.} = object
    advertisements* {.fieldNumber: 1.}: seq[seq[byte]] # field 1 - List of encoded advertisements

  Message* = object
    msgType*: MessageType
    key*: seq[byte]
    record*: Opt[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]
    providerStatus*: Opt[AddProviderStatus]
      # field 11 - ADD_PROVIDER response status (nim extension)
    register*: Opt[RegisterMessage] # field 21 -  REGISTER message
    getAds*: Opt[GetAdsMessage] # field 22 -  GET_ADS message

proc hash*(peer: Peer): Hash =
  hash(peer.id)

proc `==`*(a, b: Peer): bool =
  a.id == b.id

proc hide(
    connStatus: ConnectionStatus, hideConnectionStatus: bool
): ConnectionStatus {.raises: [], gcsafe.} =
  if hideConnectionStatus:
    return ConnectionStatus.notConnected
  return connStatus

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [], gcsafe.}

proc writeOpt*[T](pb: var ProtoBuffer, field: int, opt: Opt[T]) {.raises: [], gcsafe.}

proc encode*(record: Record): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.write(1, record.key)
  pb.writeOpt(2, record.value)
  pb.writeOpt(5, record.timeReceived)
  pb.finish()
  return pb

proc encode*(
    peer: Peer, hideConnectionStatus: bool = true
): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.write(1, peer.id)
  for address in peer.addrs:
    pb.write(2, address.data.buffer)
  pb.write(3, peer.connection.hide(hideConnectionStatus).ord.uint32)
  pb.finish()
  return pb

proc toMsg(t: Ticket): TicketMsg =
  TicketMsg(
    advertisement: t.advertisement,
    tInit: t.tInit.epochSeconds.uint64,
    tMod: t.tMod.epochSeconds.uint64,
    tWaitFor: t.tWaitFor.seconds.uint32,
    signature:
      if t.signature.len > 0: Opt.some(t.signature) else: Opt.none(seq[byte]),
  )

proc toTicket(m: TicketMsg): Ticket =
  Ticket(
    advertisement: m.advertisement,
    tInit: Moment.init(cast[int64](m.tInit), Second),
    tMod: Moment.init(cast[int64](m.tMod), Second),
    tWaitFor: m.tWaitFor.secs,
    signature: m.signature.get(@[]),
  )

Protobuf.serializerFor([TicketMsg])

Protobuf.extensionDefaults(Ticket, defaultWriteSeq = false)

func computeFieldSize*(
    field: int,
    value: Ticket,
    ProtoType: type ProtobufExt,
    skipDefault: static bool,
): int =
  computeFieldSize(field, value.toMsg().encode(), pbytes, skipDefault)

proc writeField*(
    stream: OutputStream,
    field: int,
    value: Ticket,
    ProtoType: type ProtobufExt,
    skipDefault: static bool = false,
) {.raises: [IOError].} =
  writeField(stream, field, value.toMsg().encode(), pbytes, skipDefault)

proc readFieldInto*(
    stream: InputStream,
    value: var Ticket,
    header: FieldHeader,
    ProtoType: type ProtobufExt,
): bool {.raises: [SerializationError, IOError].} =
  var data = default(seq[byte])
  if readFieldInto(stream, data, header, pbytes):
    let ticketMsg = TicketMsg.decode(data).valueOr:
      raise (ref ProtobufValueError)(msg: "Invalid Ticket")
    value = ticketMsg.toTicket()
    true
  else:
    false

Protobuf.serializerFor([RegisterMessage, GetAdsMessage])

proc encode*(
    msg: Message, hideConnectionStatus: bool = true
): ProtoBuffer {.raises: [], gcsafe.} =
  var pb = initProtoBuffer()

  pb.write(1, uint32(ord(msg.msgType)))

  pb.write(2, msg.key)

  pb.writeOpt(3, msg.record)

  for peer in msg.closerPeers:
    pb.write(8, peer.encode(hideConnectionStatus))

  for peer in msg.providerPeers:
    pb.write(9, peer.encode(hideConnectionStatus))

  msg.providerStatus.withValue(status):
    pb.write(11, uint32(ord(status)))

  msg.register.withValue(regMsg):
    pb.write(21, regMsg.encode())

  msg.getAds.withValue(getAdsMsg):
    pb.write(22, getAdsMsg.encode())

  pb.finish()

  return pb

proc writeOpt*[T](pb: var ProtoBuffer, field: int, opt: Opt[T]) {.raises: [], gcsafe.} =
  opt.withValue(v):
    pb.write(field, v)

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [], gcsafe.} =
  pb.write(field, value.encode())

proc decodeEnum[T: enum](val: uint32): ProtoResult[T] =
  var e: T
  if not checkedEnumAssign(e, val):
    return err(ProtoError.BadWireType)
  ok(e)

proc getOptionField[T: ProtoScalar | string | seq[byte]](
    pb: ProtoBuffer, field: int, output: var Opt[T]
): ProtoResult[void] =
  var f: T
  if ?pb.getField(field, f):
    output = Opt.some(f)
  ok()

proc decode*(T: type Record, pb: ProtoBuffer): ProtoResult[T] =
  var r: Record
  ?pb.getRequiredField(1, r.key)
  ?pb.getOptionField(2, r.value)
  ?pb.getOptionField(5, r.timeReceived)
  return ok(r)

proc decode*(T: type Peer, pb: ProtoBuffer): ProtoResult[T] =
  var p: Peer

  ?pb.getRequiredField(1, p.id)

  discard ?pb.getRepeatedField(2, p.addrs)

  var connVal: uint32
  if ?pb.getField(3, connVal):
    p.connection = ?decodeEnum[ConnectionStatus](connVal)

  return ok(p)

proc decode*(T: type Message, pb: ProtoBuffer): ProtoResult[T] =
  var
    m: Message
    recPb: seq[byte]
    closerPbs: seq[seq[byte]]
    providerPbs: seq[seq[byte]]

  var msgTypeVal: uint32
  ?pb.getRequiredField(1, msgTypeVal)
  m.msgType = ?decodeEnum[MessageType](msgTypeVal)

  discard ?pb.getField(2, m.key)

  if ?pb.getField(3, recPb):
    # Could be either a Record for standard KadDHT messages
    if m.msgType in {MessageType.putValue, MessageType.getValue}:
      m.record = Opt.some(?Record.decode(initProtoBuffer(recPb)))

  discard ?pb.getRepeatedField(8, closerPbs)
  for ppb in closerPbs:
    m.closerPeers.add(?Peer.decode(initProtoBuffer(ppb)))

  discard ?pb.getRepeatedField(9, providerPbs)
  for ppb in providerPbs:
    m.providerPeers.add(?Peer.decode(initProtoBuffer(ppb)))

  var providerStatusVal: uint32
  if ?pb.getField(11, providerStatusVal):
    m.providerStatus = Opt.some(?decodeEnum[AddProviderStatus](providerStatusVal))

  # Decode Register message (field 21)
  var regBuf: seq[byte]
  if ?pb.getField(21, regBuf):
    let regMsg = RegisterMessage.decode(regBuf).valueOr:
      return err(ProtoError.IncorrectBlob)
    m.register = Opt.some(regMsg)

  # Decode GetAds message (field 22)
  var getAdsBuf: seq[byte]
  if ?pb.getField(22, getAdsBuf):
    let getAdsMsg = GetAdsMessage.decode(getAdsBuf).valueOr:
      return err(ProtoError.IncorrectBlob)
    m.getAds = Opt.some(getAdsMsg)

  return ok(m)

proc decode*(T: type Message, buf: sink seq[byte]): ProtoResult[T] =
  var pb = initProtoBuffer(move(buf))
  return Message.decode(pb)

proc toBytes*(ticket: Ticket): seq[byte] {.raises: [], gcsafe.} =
  ## Returns the canonical byte representation of a Ticket used for signing.
  ## Covers: advertisement || tInit || tMod || tWaitFor
  var buf = newSeqOfCap[byte](ticket.advertisement.len + 8 + 8 + 4)
  buf.add(ticket.advertisement)
  buf.add(@(toBytesBE(ticket.tInit.epochSeconds.uint64)))
  buf.add(@(toBytesBE(ticket.tMod.epochSeconds.uint64)))
  buf.add(@(toBytesBE(ticket.tWaitFor.seconds.uint32)))
  buf

proc sign*(
    ticket: var Ticket, privateKey: PrivateKey
): Result[void, CryptoError] {.raises: [], gcsafe.} =
  ## Sign the ticket with the given private key.
  let sig = ?privateKey.sign(ticket.toBytes())
  ticket.signature = sig.getBytes()
  ok()

proc verify*(ticket: Ticket, publicKey: PublicKey): bool {.raises: [], gcsafe.} =
  ## Verify the ticket signature against the given public key.
  var sig: Signature
  if not sig.init(ticket.signature):
    return false
  sig.verify(ticket.toBytes(), publicKey)

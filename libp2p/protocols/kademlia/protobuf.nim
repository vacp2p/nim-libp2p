# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/hashes
import chronos
import ../../utils/opt
import results
import ../../multiaddress
import stew/endians2
import ../../crypto/crypto
import protobuf_serialization
import protobuf_serialization/pkg/results
import protobuf_serialization/std/enums
import ../../utils/protobuf

type
  Record* {.proto3.} = object
    key* {.fieldNumber: 1.}: seq[byte]
    value* {.fieldNumber: 2.}: Opt[seq[byte]]
    timeReceived* {.fieldNumber: 5.}: Opt[string]

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

  Peer* {.proto3.} = object
    id* {.fieldNumber: 1.}: seq[byte]
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]
    connection* {.fieldNumber: 3, ext.}: ConnectionStatus

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

  TicketMsg {.proto3.} = object
    advertisement {.fieldNumber: 1.}: seq[byte]
    tInit {.fieldNumber: 2, pint.}: uint64
    tMod {.fieldNumber: 3, pint.}: uint64
    tWaitFor {.fieldNumber: 4, pint.}: uint32
    signature {.fieldNumber: 5.}: Opt[seq[byte]]

  # Register message for Service Discovery
  # Field 21 in the main Message
  RegisterMessage* {.proto3.} = object
    advertisement* {.fieldNumber: 1.}: seq[byte] # field 1 - Encoded advertisement
    status* {.fieldNumber: 2, ext.}: Opt[RegistrationStatus]
      # field 2 - Registration status (response only)
    ticket* {.fieldNumber: 3, ext.}: Opt[Ticket] # field 3 - Optional ticket

  # GetAds message for Service Discovery
  # Field 22 in the main Message
  GetAdsMessage* {.proto2.} = object
    advertisements* {.fieldNumber: 1.}: seq[seq[byte]]
      # field 1 - List of encoded advertisements

  Message* {.proto3.} = object
    msgType* {.fieldNumber: 1, ext.}: MessageType
    key* {.fieldNumber: 2.}: seq[byte]
    record* {.fieldNumber: 3.}: Opt[Record]
    closerPeers* {.fieldNumber: 8.}: seq[Peer]
    providerPeers* {.fieldNumber: 9.}: seq[Peer]
    providerStatus* {.fieldNumber: 11, ext.}: Opt[AddProviderStatus]
    register* {.fieldNumber: 21.}: Opt[RegisterMessage]
    getAds* {.fieldNumber: 22.}: Opt[GetAdsMessage]

proc hash*(peer: Peer): Hash =
  hash(peer.id)

proc `==`*(a, b: Peer): bool =
  a.id == b.id

proc toMsg(t: Ticket): TicketMsg =
  TicketMsg(
    advertisement: t.advertisement,
    tInit: t.tInit.epochSeconds.uint64,
    tMod: t.tMod.epochSeconds.uint64,
    tWaitFor: t.tWaitFor.seconds.uint32,
    signature:
      if t.signature.len > 0:
        Opt.some(t.signature)
      else:
        Opt.none(seq[byte]),
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
    field: int, value: Ticket, ProtoType: type ProtobufExt, skipDefault: static bool
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

Protobuf.serializerFor([Record, RegisterMessage, GetAdsMessage])

proc decodePeer(buf: seq[byte]): Peer {.raises: [SerializationError].} =
  Protobuf.decode(buf, Peer)

proc decode*(_: type Peer, buf: seq[byte]): Result[Peer, string] =
  try:
    ok(decodePeer(buf))
  except SerializationError as e:
    err("failed to decode Peer from protobuf bytes. " & e.msg)

proc encode*(
    msg: Peer, hideConnectionStatus: bool = true
): seq[byte] {.raises: [], gcsafe.} =
  var m = msg
  if hideConnectionStatus:
    m.connection = ConnectionStatus.notConnected
  Protobuf.encode(m)

proc decodeMessage(buf: seq[byte]): Message {.raises: [SerializationError].} =
  Protobuf.decode(buf, Message)

proc decode*(_: type Message, buf: seq[byte]): Result[Message, string] =
  try:
    ok(decodeMessage(buf))
  except SerializationError as e:
    err("failed to decode Message from protobuf bytes. " & e.msg)

proc encode*(
    msg: Message, hideConnectionStatus: bool = true
): seq[byte] {.raises: [], gcsafe.} =
  var m = msg
  if hideConnectionStatus:
    for p in m.closerPeers.mitems:
      p.connection = ConnectionStatus.notConnected
    for p in m.providerPeers.mitems:
      p.connection = ConnectionStatus.notConnected
  Protobuf.encode(m)

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

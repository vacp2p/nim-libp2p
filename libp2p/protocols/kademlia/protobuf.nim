# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/options
import ../../protobuf/minprotobuf
import ../../varint
import ../../utility
import results
import ../../multiaddress
import stew/objects

type
  Record* {.public.} = object
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
    register = 16 # REGISTER for Capability Discovery
    getAds = 17 # GET_ADS for Capability Discovery

  ConnectionType* = enum
    notConnected = 0
    connected = 1
    canConnect = 2 # Unused
    cannotConnect = 3 # Unused

  Peer* {.public.} = object
    id*: seq[byte]
    addrs*: seq[MultiAddress]
    connection*: ConnectionType

  # Registration status for Capability Discovery
  RegistrationStatus* = enum
    Confirmed = 0
    Wait = 1
    Rejected = 2

  # Ticket message for Capability Discovery
  # Nested within Register message
  Ticket* {.public.} = object
    advertisement*: seq[byte] # field 1 - Copy of the original advertisement
    tInit*: uint64 # field 2 - Ticket creation timestamp (Unix time in seconds)
    tMod*: uint64 # field 3 - Last modification timestamp (Unix time in seconds)
    tWaitFor*: uint32 # field 4 - Remaining wait time in seconds
    signature*: seq[byte] # field 5 - Ed25519 signature

  # Register message for Capability Discovery
  # Field 21 in the main Message
  RegisterMessage* {.public.} = object
    advertisement*: seq[byte] # field 1 - Encoded advertisement
    status*: Opt[RegistrationStatus] # field 2 - Registration status (response only)
    ticket*: Opt[Ticket] # field 3 - Optional ticket

  # GetAds message for Capability Discovery
  # Field 22 in the main Message
  GetAdsMessage* {.public.} = object
    advertisements*: seq[seq[byte]] # field 1 - List of encoded advertisements

  Message* {.public.} = object
    msgType*: MessageType
    key*: seq[byte]
    record*: Opt[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]
    register*: Opt[RegisterMessage] # field 21 -  REGISTER message
    getAds*: Opt[GetAdsMessage] # field 22 -  GET_ADS message

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [], gcsafe.}

proc writeOpt*[T](pb: var ProtoBuffer, field: int, opt: Opt[T]) {.raises: [], gcsafe.}

proc encode*(record: Record): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.write(1, record.key)
  pb.writeOpt(2, record.value)
  pb.writeOpt(5, record.timeReceived)
  pb.finish()
  return pb

proc encode*(peer: Peer): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.write(1, peer.id)
  for address in peer.addrs:
    pb.write(2, address.data.buffer)
  pb.write(3, uint32(ord(peer.connection)))
  pb.finish()
  return pb

proc encode*(ticket: Ticket): ProtoBuffer {.raises: [], gcsafe.} =
  ## Encode Ticket to protobuf format
  var pb = initProtoBuffer()
  pb.write(1, ticket.advertisement)
  pb.write(2, ticket.tInit)
  pb.write(3, ticket.tMod)
  pb.write(4, ticket.tWaitFor)
  if ticket.signature.len > 0:
    pb.write(5, ticket.signature)
  pb.finish()
  return pb

proc encode*(regMsg: RegisterMessage): ProtoBuffer {.raises: [], gcsafe.} =
  ## Encode RegisterMessage to protobuf format
  var pb = initProtoBuffer()
  pb.write(1, regMsg.advertisement)

  regMsg.status.withValue(statusVal):
    pb.write(2, uint32(ord(statusVal)))

  regMsg.ticket.withValue(ticketVal):
    pb.write(3, ticketVal.encode())

  pb.finish()
  return pb

proc encode*(getAdsMsg: GetAdsMessage): ProtoBuffer {.raises: [], gcsafe.} =
  ## Encode GetAdsMessage to protobuf format
  var pb = initProtoBuffer()
  for ad in getAdsMsg.advertisements:
    pb.write(1, ad)
  pb.finish()
  return pb

proc encode*(msg: Message): ProtoBuffer {.raises: [], gcsafe.} =
  var pb = initProtoBuffer()

  pb.write(1, uint32(ord(msg.msgType)))

  pb.write(2, msg.key)

  msg.record.withValue(record):
    pb.writeOpt(3, msg.record)

  for peer in msg.closerPeers:
    pb.write(8, peer.encode())

  for peer in msg.providerPeers:
    pb.write(9, peer.encode())

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
  var
    p: Peer
    id: seq[byte]

  ?pb.getRequiredField(1, p.id)

  discard ?pb.getRepeatedField(2, p.addrs)

  var connVal: uint32
  if ?pb.getField(3, connVal):
    var connType: ConnectionType
    if not checkedEnumAssign(connType, connVal):
      return err(ProtoError.BadWireType)
    p.connection = connType

  return ok(p)

proc decode*(T: type Ticket, pb: ProtoBuffer): ProtoResult[T] =
  ## Decode Ticket from protobuf format
  var ticket =
    Ticket(advertisement: @[], tInit: 0, tMod: 0, tWaitFor: 0, signature: @[])

  discard ?pb.getField(1, ticket.advertisement)

  discard ?pb.getField(2, ticket.tInit)
  discard ?pb.getField(3, ticket.tMod)
  discard ?pb.getField(4, ticket.tWaitFor)

  discard ?pb.getField(5, ticket.signature)

  return ok(ticket)

proc decode*(T: type RegisterMessage, pb: ProtoBuffer): ProtoResult[T] =
  ## Decode RegisterMessage from protobuf format
  var regMsg = RegisterMessage(
    advertisement: @[], status: Opt.none(RegistrationStatus), ticket: Opt.none(Ticket)
  )

  discard ?pb.getField(1, regMsg.advertisement)

  var statusVal: uint32
  if ?pb.getField(2, statusVal):
    var status: RegistrationStatus
    if checkedEnumAssign(status, statusVal):
      regMsg.status = Opt.some(status)

  var ticketBuf: seq[byte]
  if ?pb.getField(3, ticketBuf):
    let ticket = ?Ticket.decode(initProtoBuffer(ticketBuf))
    regMsg.ticket = Opt.some(ticket)

  return ok(regMsg)

proc decode*(T: type GetAdsMessage, pb: ProtoBuffer): ProtoResult[T] =
  ## Decode GetAdsMessage from protobuf format
  var getAdsMsg = GetAdsMessage(advertisements: @[])

  discard ?pb.getRepeatedField(1, getAdsMsg.advertisements)

  return ok(getAdsMsg)

proc decode*(T: type Message, pb: ProtoBuffer): ProtoResult[T] =
  var
    m: Message
    recPb: seq[byte]
    closerPbs: seq[seq[byte]]
    providerPbs: seq[seq[byte]]

  var msgTypeVal: uint32
  ?pb.getRequiredField(1, msgTypeVal)

  var msgType: MessageType
  if not checkedEnumAssign(msgType, msgTypeVal):
    return err(ProtoError.BadWireType)

  m.msgType = msgType

  discard ?pb.getField(2, m.key)

  if ?pb.getField(3, recPb):
    # Could be either a Record for standard KadDHT messages
    if msgType in {MessageType.putValue, MessageType.getValue}:
      m.record = Opt.some(?Record.decode(initProtoBuffer(recPb)))

  discard ?pb.getRepeatedField(8, closerPbs)
  for ppb in closerPbs:
    m.closerPeers.add(?Peer.decode(initProtoBuffer(ppb)))

  discard ?pb.getRepeatedField(9, providerPbs)
  for ppb in providerPbs:
    m.providerPeers.add(?Peer.decode(initProtoBuffer(ppb)))

  # Decode Register message (field 21)
  var regBuf: seq[byte]
  if ?pb.getField(21, regBuf):
    let regMsg = ?RegisterMessage.decode(initProtoBuffer(regBuf))
    m.register = Opt.some(regMsg)

  # Decode GetAds message (field 22)
  var getAdsBuf: seq[byte]
  if ?pb.getField(22, getAdsBuf):
    let getAdsMsg = ?GetAdsMessage.decode(initProtoBuffer(getAdsBuf))
    m.getAds = Opt.some(getAdsMsg)

  return ok(m)

proc decode*(T: type Message, buf: seq[byte]): ProtoResult[T] =
  var pb = initProtoBuffer(buf)
  return Message.decode(pb)

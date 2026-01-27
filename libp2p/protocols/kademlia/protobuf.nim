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
    register = 6 # REGISTER for Logos Capability Discovery
    getAds = 7 # GET_ADS for Logos Capability Discovery

  ConnectionType* = enum
    notConnected = 0
    connected = 1
    canConnect = 2 # Unused
    cannotConnect = 3 # Unused

  Peer* {.public.} = object
    id*: seq[byte]
    addrs*: seq[MultiAddress]
    connection*: ConnectionType

  Message* {.public.} = object
    msgType*: MessageType
    key*: seq[byte]
    record*: Opt[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]
    ad*: Opt[seq[byte]]
    ads*: seq[seq[byte]]
    ticket*: Opt[seq[byte]]
    status*: Opt[uint32]

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

  msg.ad.withValue(adBuf):
    pb.write(3, adBuf)

  for adBuf in msg.ads:
    pb.write(2, adBuf)

  msg.ticket.withValue(ticketBuf):
    pb.write(4, ticketBuf)

  msg.status.withValue(statusVal):
    pb.write(2, statusVal)

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
    # Could be either a Record or an Advertisement depending on message type
    if msgType in {MessageType.putValue, MessageType.getValue}:
      m.record = Opt.some(?Record.decode(initProtoBuffer(recPb)))
    else:
      m.ad = Opt.some(recPb)

  discard ?pb.getRepeatedField(8, closerPbs)
  for ppb in closerPbs:
    m.closerPeers.add(?Peer.decode(initProtoBuffer(ppb)))

  discard ?pb.getRepeatedField(9, providerPbs)
  for ppb in providerPbs:
    m.providerPeers.add(?Peer.decode(initProtoBuffer(ppb)))

  var adBufs: seq[seq[byte]]
  discard ?pb.getRepeatedField(2, adBufs)
  m.ads = adBufs

  var ticketBuf: seq[byte]
  if ?pb.getField(4, ticketBuf):
    m.ticket = Opt.some(ticketBuf)

  var statusVal: uint32
  if ?pb.getField(2, statusVal):
    m.status = Opt.some(statusVal)

  return ok(m)

proc decode*(T: type Message, buf: seq[byte]): ProtoResult[T] =
  var pb = initProtoBuffer(buf)
  return Message.decode(pb)

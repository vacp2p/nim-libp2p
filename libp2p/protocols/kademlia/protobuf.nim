import ../../protobuf/minprotobuf
import ../../varint
import results
import ../../multiaddress
import stew/objects

type
  Record* {.public.} = object
    key*: Opt[seq[byte]]
    value*: Opt[seq[byte]]
    timeReceived*: Opt[string]

  MessageType* {.pure.} = enum
    putValue = 0
    getValue = 1
    addProvider = 2
    getProviders = 3
    findNode = 4
    ping = 5 # Deprecated

  ConnectionType* {.pure.} = enum
    notConnected = 0
    connected = 1
    canConnect = 2 # Unused
    cannotConnect = 3 # Unused

  Peer* {.public.} = object
    id*: seq[byte]
    addrs*: seq[MultiAddress]
    connection*: ConnectionType

  Message* {.public.} = object
    msgType*: Opt[MessageType]
    key*: Opt[seq[byte]]
    record*: Opt[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [].}

proc writeOpt*[T](pb: var ProtoBuffer, field: int, opt: Opt[T]) {.raises: [].} =
  opt.withValue(v):
    pb.write(field, v)

proc encode*(record: Record): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.writeOpt(1, record.key)
  pb.writeOpt(2, record.value)
  pb.writeOpt(5, record.timeReceived)
  pb.finish()
  return pb

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [].} =
  pb.write(field, value.encode())

proc encode*(peer: Peer): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.write(1, peer.id)
  for address in peer.addrs:
    pb.write(2, address.data.buffer)
  pb.write(3, uint32(ord(peer.connection)))
  pb.finish()
  return pb

proc encode*(msg: Message): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  msg.msgType.withValue(msgType):
    pb.write(1, uint32(ord(msgType)))

  pb.writeOpt(2, msg.key)

  msg.record.withValue(record):
    pb.writeOpt(3, msg.record)

  for peer in msg.closerPeers:
    pb.write(8, peer.encode())

  for peer in msg.providerPeers:
    pb.write(9, peer.encode())

  pb.finish()

  return pb

proc decode*(T: type Record, pb: ProtoBuffer): Opt[T] =
  var
    r: Record
    key: seq[byte]
    value: seq[byte]
    timeReceived: string

  if ?pb.getField(1, key).toOpt():
    r.key = Opt.some(key)

  if ?pb.getField(2, value).toOpt():
    r.value = Opt.some(value)

  if ?pb.getField(5, timeReceived).toOpt():
    r.timeReceived = Opt.some(timeReceived)

  Opt.some(r)

proc decode*(T: type Peer, pb: ProtoBuffer): Opt[T] =
  var
    p: Peer
    id: seq[byte]

  if ?pb.getField(1, id).toOpt():
    p.id = id
  else:
    return Opt.none(T)

  discard pb.getRepeatedField(2, p.addrs)

  var connVal: uint32
  if ?pb.getField(3, connVal).toOpt():
    var connType: ConnectionType
    if not checkedEnumAssign(connType, connVal):
      return Opt.none(T)
    p.connection = connType

  return Opt.some(p)

proc decode*(T: type Message, buf: seq[byte]): Opt[T] =
  var
    m: Message
    key: seq[byte]
    recPb: seq[byte]
    closerPbs: seq[seq[byte]]
    providerPbs: seq[seq[byte]]

  var pb = initProtoBuffer(buf)

  var msgTypeVal: uint32
  if not ?pb.getField(1, msgTypeVal).toOpt():
    return Opt.none(T)
  else:
    var msgType: MessageType
    if not checkedEnumAssign(msgType, msgTypeVal):
      return Opt.none(T)
    m.msgType = Opt.some(msgType)

  if ?pb.getField(2, key).toOpt():
    m.key = Opt.some(key)

  if ?pb.getField(3, recPb).toOpt():
    m.record = Record.decode(initProtoBuffer(recPb))

  discard ?pb.getRepeatedField(8, closerPbs).toOpt()
  for ppb in closerPbs:
    let peer = Peer.decode(initProtoBuffer(ppb))
    if peer.isSome:
      m.closerPeers.add(peer.unsafeGet())

  discard ?pb.getRepeatedField(9, providerPbs).toOpt()
  for ppb in providerPbs:
    let peer = Peer.decode(initProtoBuffer(ppb))
    if peer.isSome:
      m.providerPeers.add(peer.unsafeGet())

  return Opt.some(m)

import ../../protobuf/minprotobuf
import ../../varint
import results
import ../../multiaddress

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
    ping = 5

  ConnectionType* {.pure.} = enum
    notConnected = 0
    connected = 1
    canConnect = 2
    cannotConnect = 3

  Peer* {.public.} = object
    id*: Opt[seq[byte]]
    addrs*: seq[MultiAddress]
    connection*: Opt[ConnectionType]

  Message* {.public.} = object
    msgType*: Opt[MessageType]
    clusterLevelRaw*: Opt[int32]
    key*: Opt[seq[byte]]
    record*: Opt[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]

proc writeOpt*[T](pb: var ProtoBuffer, field: int, opt: Opt[T]) {.raises: [].} =
  opt.withValue(v):
    pb.write(field, v)

proc encodeRecord*(record: Record): ProtoBuffer {.raises: [].} =
  result = initProtoBuffer()
  result.writeOpt(1, record.key)
  result.writeOpt(2, record.value)
  result.writeOpt(5, record.timeReceived)

proc write*(pb: var ProtoBuffer, field: int, opt: Opt[Record]) {.raises: [].} =
  if opt.isSome:
    pb.write(field, opt.get().encodeRecord())

proc encodePeer*(peer: Peer): ProtoBuffer {.raises: [].} =
  result = initProtoBuffer()
  peer.id.withValue(id):
    result.write(1, id)
  for address in peer.addrs:
    result.write(2, address.data.buffer)
  peer.connection.withValue(connection):
    result.write(3, uint32(ord(connection)))

proc encodeMessage*(msg: Message): ProtoBuffer {.raises: [].} =
  result = initProtoBuffer()
  msg.msgType.withValue(msgType):
    result.write(1, uint32(ord(msgType)))

  result.writeOpt(2, msg.key)
  result.write(3, msg.record)

  for peer in msg.closerPeers:
    result.write(8, peer.encodePeer())

  for peer in msg.providerPeers:
    result.write(9, peer.encodePeer())

  msg.clusterLevelRaw.withValue(clusterLevelRaw):
    result.write(10, uint32(clusterLevelRaw))

proc decodeRecord*(pb: ProtoBuffer): Opt[Record] =
  var
    r: Record
    key: seq[byte]
    value: seq[byte]
    timeReceived: string

  if ?pb.getField(1, key):
    r.key = Opt.some(key)

  if ?pb.getField(2, value):
    r.value = Opt.some(value)

  if ?pb.getField(5, timeReceived):
    r.timeReceived = Opt.some(timeReceived)

  Opt.some(r)

proc decodePeer*(pb: ProtoBuffer): Result[Opt[Peer], string] =
  var
    p: Peer
    id: seq[byte]

  if ?pb.getField(1, id):
    p.id = Opt.some(id)

  discard pb.getRepeatedField(2, p.addrs)

  var connVal: uint32
  if ?pb.getField(3, connVal):
    if connVal in ConnectionType.low .. ConnectionType.high:
      p.connection = Opt.some(ConnectionType(connVal))
    else:
      return err("invalid connection type")

  ok(Opt.some(p))

proc decodeMessage*(buf: seq[byte]): Result[Opt[Message], string] =
  var
    m: Message
    key: seq[byte]
    recPb: seq[byte]
    closerPbs: seq[seq[byte]]
    providerPbs: seq[seq[byte]]
    clusterLevelRaw: uint32

  var pb = initProtoBuffer(buf)

  var msgTypeVal: uint32
  if ?pb.getField(1, msgTypeVal).toOpt():
    if msgTypeVal in MessageType.low .. MessageType.high:
      m.msgType = Opt.some(MessageType(msgTypeVal))
    else:
      return err("invalid message type")

  if ?pb.getField(2, key).toOpt():
    m.key = Opt.some(key)

  if ?pb.getField(3, recPb).toOpt():
    m.record = decodeRecord(initProtoBuffer(recPb))

  discard ?pb.getRepeatedField(8, closerPbs).toOpt()
  for ppb in closerPbs:
    let peer = decodePeer(initProtoBuffer(ppb))
    if peer.isErr:
      return err(peer.error())
    m.closerPeers.add ?peer.unsafeGet()

  discard ?pb.getRepeatedField(9, providerPbs).toOpt()
  for ppb in providerPbs:
    let peer = decodePeer(initProtoBuffer(ppb))
    if peer.isErr:
      return err(peer.error())
    m.providerPeers.add ?peer.unsafeGet()

  if ?pb.getField(10, clusterLevelRaw).toOpt():
    m.clusterLevelRaw = Opt.some(int32(clusterLevelRaw))

  ok(Opt.some(m))

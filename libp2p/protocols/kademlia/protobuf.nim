import ../../protobuf/minprotobuf
import ../../varint
import ../../utility
import results
import ../../multiaddress
import stew/objects
import stew/assign2
import options
# import protobuf/[pbtypes, encode_decode]
# export pbtypes, encode_decode

type
  #[
TODO(Ben): ...
- Doc comment this
- Consider the Option pattern here. 
 - I don't think a record can exist without a key
 - A record that exists in a bucket implies that it _must_ have a timeReceived value
 - a `value == none` signals that an entry is empty, which would be the same as 0-len `seq`
- Consider the idiom "`Record` hase key and value, a RecordEntry has a `Record` and `TimeReceived`"
- consider `timeReceived` be a u64 millisecond representation
- Consider using distinct types:
 - Protobuf getting of fields relies on `seq[byte]`
 - mitiprotobuf has similar reqs
 - tried the `type Foo = object\n  data: seq[byte]` pattern and this caused a 
   painful breadtrail of errors
]#
  Record* {.public.} = object
    key*: Option[seq[byte]]
    value*: Option[seq[byte]]
    timeReceived*: Option[string]

  MessageType* = enum
    putValue = 0
    getValue = 1
    addProvider = 2
    getProviders = 3
    findNode = 4
    # TODO(Ben): Raise compiler warning where this deprecated variant is used
    ping = 5 # Deprecated

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
    # TODO: use distinct type
    key*: Option[seq[byte]]
    record*: Option[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [], gcsafe.}

proc writeOpt*[T](
  pb: var ProtoBuffer, field: int, opt: Option[T]
) {.raises: [], gcsafe.}

proc encode*(record: Record): ProtoBuffer {.raises: [].} =
  var pb = initProtoBuffer()
  pb.writeOpt(1, record.key)
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

  pb.writeOpt(2, msg.key)

  msg.record.withValue(record):
    pb.writeOpt(3, msg.record)

  for peer in msg.closerPeers:
    pb.write(8, peer.encode())

  for peer in msg.providerPeers:
    pb.write(9, peer.encode())

  pb.finish()

  return pb

proc writeOpt*[T](
    pb: var ProtoBuffer, field: int, opt: Option[T]
) {.raises: [], gcsafe.} =
  opt.withValue(v):
    pb.write(field, v)

proc write*(pb: var ProtoBuffer, field: int, value: Record) {.raises: [], gcsafe.} =
  pb.write(field, value.encode())

proc getOptionField[T: ProtoScalar | string | seq[byte]](
    pb: ProtoBuffer, field: int, output: var Option[T]
): ProtoResult[void] =
  var f: T
  if ?pb.getField(field, f):
    assign(output, some(f))
  ok()

proc decode*(T: type Record, pb: ProtoBuffer): ProtoResult[Option[T]] =
  var r: Record
  ?pb.getOptionField(1, r.key)
  ?pb.getOptionField(2, r.value)
  ?pb.getOptionField(5, r.timeReceived)
  return ok(some(r))

proc decode*(T: type Peer, pb: ProtoBuffer): ProtoResult[Option[T]] =
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

  return ok(some(p))

proc decode*(T: type Message, buf: seq[byte]): ProtoResult[T] =
  var
    m: Message
    key: seq[byte]
    recPb: seq[byte]
    closerPbs: seq[seq[byte]]
    providerPbs: seq[seq[byte]]

  var pb = initProtoBuffer(buf)

  var msgTypeVal: uint32
  ?pb.getRequiredField(1, msgTypeVal)

  var msgType: MessageType
  if not checkedEnumAssign(msgType, msgTypeVal):
    return err(ProtoError.BadWireType)

  m.msgType = msgType

  ?pb.getOptionField(2, m.key)

  if ?pb.getField(3, recPb):
    assign(m.record, ?Record.decode(initProtoBuffer(recPb)))

  discard ?pb.getRepeatedField(8, closerPbs)
  for ppb in closerPbs:
    let peerOpt = ?Peer.decode(initProtoBuffer(ppb))
    peerOpt.withValue(peer):
      m.closerPeers.add(peer)

  discard ?pb.getRepeatedField(9, providerPbs)
  for ppb in providerPbs:
    let peer = ?Peer.decode(initProtoBuffer(ppb))
    peer.withValue(peer):
      m.providerPeers.add(peer)

  return ok(m)

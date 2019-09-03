## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import protobuf/minprotobuf, peerinfo, 
       protocol as proto, connection,
       peer, crypto/crypto, multiaddress

const IdentifyCodec* = "/ipfs/id/1.0.0"
const IdentifyPushCodec* = "/ipfs/id/push/1.0.0"
const ProtoVersion* = "ipfs/0.1.0"
const AgentVersion* = "nim-libp2p/0.0.1"

#TODO: implment push identify, leaving out for now as it is not essential

type
  # TODO: we're doing protobuf manualy, this is only temporary
  ProtoField[T] = object
    index: int
    field: T

  IdentifyInfo* = object
    pubKey*: PublicKey
    addrs*: seq[MultiAddress]
    observedAddr*: MultiAddress
    protoVersion*: string
    agentVersion*: string
    protos*: seq[string]

  Identify* = ref object of LPProtocol
    peerInfo*: PeerInfo

proc encodeMsg*(peerInfo: PeerInfo, observedAddrs: Multiaddress): ProtoBuffer = 
  result = initProtoBuffer()

  result.write(initProtoField(1, peerInfo.peerId.publicKey.getBytes()))
  for ma in peerInfo.addrs:
    result.write(initProtoField(2, ma.data.buffer))

  for proto in peerInfo.protocols:
    result.write(initProtoField(3, proto))

  result.write(initProtoField(4, observedAddrs.data.buffer))

  let protoVersion = ProtoVersion
  result.write(initProtoField(5, protoVersion))

  let agentVersion = AgentVersion
  result.write(initProtoField(6, agentVersion))
  result.finish()

proc decodeMsg*(buf: seq[byte]): IdentifyInfo = 
  var pb = initProtoBuffer(buf)

  discard pb.getValue(1, result.pubKey)

  result.addrs = newSeq[MultiAddress]()
  var address = newSeq[byte]()
  while pb.getBytes(2, address) != -1:
    if len(address) != 0:
      var copyaddr = address
      result.addrs.add(MultiAddress.init(copyaddr))
      address.setLen(0)

  var proto = ""
  while pb.getString(3, proto) > 0:
    result.protos.add(proto)
    proto = ""
  
  var observableAddr = newSeq[byte]()
  if pb.getBytes(4, observableAddr) > 0: # attempt to read the observed addr
    result.observedAddr = MultiAddress.init(observableAddr)

  discard pb.getString(5, result.protoVersion)
  discard pb.getString(6, result.agentVersion)

proc newIdentify*(peerInfo: PeerInfo): Identify =
  new result
  result.peerInfo = peerInfo
  result.init()

method init*(p: Identify) = 
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var pb = encodeMsg(p.peerInfo, await conn.getObservedAddrs())
    await conn.writeLp(pb.buffer)

  p.handler = handle

proc identify*(p: Identify, conn: Connection): Future[IdentifyInfo] {.async.} = 
  var message = await conn.readLp()
  if len(message) == 0:
    raise newException(CatchableError, "Incorrect or empty message received!")
  result = decodeMsg(message)

proc push*(p: Identify, conn: Connection) {.async.} =
  await conn.write(IdentifyPushCodec)
  var pb = encodeMsg(p.peerInfo, await conn.getObservedAddrs())
  let length = pb.getLen()
  await conn.writeLp(pb.buffer)

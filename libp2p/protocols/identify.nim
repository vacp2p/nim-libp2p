## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options, strformat
import chronos, chronicles
import ../protobuf/minprotobuf, 
       ../peerinfo,
       ../connection,
       ../peer, 
       ../crypto/crypto, 
       ../multiaddress,
       ../protocols/protocol

logScope:
  topic = "identify"

const IdentifyCodec* = "/ipfs/id/1.0.0"
const IdentifyPushCodec* = "/ipfs/id/push/1.0.0"
const ProtoVersion* = "ipfs/0.1.0"
const AgentVersion* = "nim-libp2p/0.0.1"

#TODO: implment push identify, leaving out for now as it is not essential

type
  IdentityNoMatchError* = object of CatchableError
  IdentityInvalidMsgError* = object of CatchableError

  IdentifyInfo* = object
    pubKey*: Option[PublicKey]
    addrs*: seq[MultiAddress]
    observedAddr*: Option[MultiAddress]
    protoVersion*: Option[string]
    agentVersion*: Option[string]
    protos*: seq[string]

  Identify* = ref object of LPProtocol
    peerInfo*: PeerInfo

proc encodeMsg*(peerInfo: PeerInfo, observedAddrs: Multiaddress): ProtoBuffer = 
  result = initProtoBuffer()

  if peerInfo.peerId.isSome:
    result.write(initProtoField(1, peerInfo.peerId.get().publicKey.getBytes()))

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

  result.pubKey = none(PublicKey)
  var pubKey: PublicKey
  if pb.getValue(1, pubKey) > 0:
    result.pubKey = some(pubKey)

  result.addrs = newSeq[MultiAddress]()
  var address = newSeq[byte]()
  while pb.getBytes(2, address) > 0:
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
    result.observedAddr = some(MultiAddress.init(observableAddr))

  var protoVersion = ""
  if pb.getString(5, protoVersion) > 0:
    result.protoVersion = some(protoVersion)

  var agentVersion = ""
  if pb.getString(6, agentVersion) > 0:
    result.agentVersion = some(protoVersion)

proc newIdentify*(peerInfo: PeerInfo): Identify =
  new result
  result.peerInfo = peerInfo
  result.init()

method init*(p: Identify) = 
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    var pb = encodeMsg(p.peerInfo, await conn.getObservedAddrs())
    await conn.writeLp(pb.buffer)

  p.handler = handle
  p.codec = IdentifyCodec

proc identify*(p: Identify, 
               conn: Connection, 
               remotePeerInfo: PeerInfo): 
               Future[IdentifyInfo] {.async.} = 
  var message = await conn.readLp()
  if len(message) == 0:
    debug "identify: Invalid or empty message received!"
    raise newException(IdentityInvalidMsgError, 
      "Invalid or empty message received!")

  result = decodeMsg(message)
  debug "identify: Identify for remote peer succeded"

  if remotePeerInfo.peerId.isSome and 
     result.pubKey.isSome and
     result.pubKey.get() != remotePeerInfo.peerId.get().publicKey:
    debug "identify: Peer's remote public key doesn't match"
    raise newException(IdentityNoMatchError, 
      "Peer's remote public key doesn't match")

proc push*(p: Identify, conn: Connection) {.async.} =
  await conn.write(IdentifyPushCodec)
  var pb = encodeMsg(p.peerInfo, await conn.getObservedAddrs())
  let length = pb.getLen()
  await conn.writeLp(pb.buffer)

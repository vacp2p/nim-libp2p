## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronos, chronicles
import ../protobuf/minprotobuf,
       ../peerinfo,
       ../connection,
       ../peer,
       ../crypto/crypto,
       ../multiaddress,
       ../protocols/protocol,
       ../utility

logScope:
  topic = "identify"

const
  IdentifyCodec* = "/ipfs/id/1.0.0"
  IdentifyPushCodec* = "/ipfs/id/push/1.0.0"
  ProtoVersion* = "ipfs/0.1.0"
  AgentVersion* = "nim-libp2p/0.0.1"

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

  result.write(initProtoField(1, peerInfo.publicKey.get().getBytes()))

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
    trace "read public key from message", pubKey = ($pubKey).shortLog
    result.pubKey = some(pubKey)

  result.addrs = newSeq[MultiAddress]()
  var address = newSeq[byte]()
  while pb.getBytes(2, address) > 0:
    if len(address) != 0:
      var copyaddr = address
      var ma = MultiAddress.init(copyaddr)
      result.addrs.add(ma)
      trace "read address bytes from message", address = ma
      address.setLen(0)

  var proto = ""
  while pb.getString(3, proto) > 0:
    trace "read proto from message", proto = proto
    result.protos.add(proto)
    proto = ""

  var observableAddr = newSeq[byte]()
  if pb.getBytes(4, observableAddr) > 0: # attempt to read the observed addr
    var ma = MultiAddress.init(observableAddr)
    trace "read observedAddr from message", address = ma
    result.observedAddr = some(ma)

  var protoVersion = ""
  if pb.getString(5, protoVersion) > 0:
    trace "read protoVersion from message", protoVersion = protoVersion
    result.protoVersion = some(protoVersion)

  var agentVersion = ""
  if pb.getString(6, agentVersion) > 0:
    trace "read agentVersion from message", agentVersion = agentVersion
    result.agentVersion = some(protoVersion)

proc newIdentify*(peerInfo: PeerInfo): Identify =
  new result
  result.peerInfo = peerInfo
  result.init()

method init*(p: Identify) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    trace "handling identify request"
    var pb = encodeMsg(p.peerInfo, await conn.getObservedAddrs())
    await conn.writeLp(pb.buffer)
    # await conn.close() #TODO: investigate why this breaks

  p.handler = handle
  p.codec = IdentifyCodec

proc identify*(p: Identify,
               conn: Connection,
               remotePeerInfo: PeerInfo): Future[IdentifyInfo] {.async, gcsafe.} =
  var message = await conn.readLp()
  if len(message) == 0:
    trace "identify: Invalid or empty message received!"
    raise newException(IdentityInvalidMsgError,
      "Invalid or empty message received!")

  result = decodeMsg(message)

  if not isNil(remotePeerInfo) and result.pubKey.isSome:
    let peer = PeerID.init(result.pubKey.get())

    # do a string comaprison of the ids,
    # because that is the only thing we
    # have in most cases
    if peer != remotePeerInfo.peerId:
      trace "Peer ids don't match",
            remote = peer.pretty(),
            local = remotePeerInfo.id

      raise newException(IdentityNoMatchError,
        "Peer ids don't match")

  trace "Identify for remote peer succeded"

proc push*(p: Identify, conn: Connection) {.async.} =
  await conn.write(IdentifyPushCodec)
  var pb = encodeMsg(p.peerInfo, await conn.getObservedAddrs())
  await conn.writeLp(pb.buffer)

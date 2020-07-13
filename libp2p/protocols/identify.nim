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
       ../stream/connection,
       ../peerid,
       ../crypto/crypto,
       ../multiaddress,
       ../protocols/protocol,
       ../utility

logScope:
  topics = "identify"

const
  IdentifyCodec* = "/ipfs/id/1.0.0"
  IdentifyPushCodec* = "/ipfs/id/push/1.0.0"
  ProtoVersion* = "ipfs/0.1.0"
  AgentVersion* = "nim-libp2p/0.0.1"

#TODO: implement push identify, leaving out for now as it is not essential

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

proc encodeMsg*(peerInfo: PeerInfo, observedAddr: Multiaddress): ProtoBuffer =
  result = initProtoBuffer()

  result.write(1, peerInfo.publicKey.get().getBytes().tryGet())

  for ma in peerInfo.addrs:
    result.write(2, ma.data.buffer)

  for proto in peerInfo.protocols:
    result.write(3, proto)

  result.write(4, observedAddr.data.buffer)

  let protoVersion = ProtoVersion
  result.write(5, protoVersion)

  let agentVersion = AgentVersion
  result.write(6, agentVersion)
  result.finish()

proc decodeMsg*(buf: seq[byte]): IdentifyInfo =
  var pb = initProtoBuffer(buf)

  var pubKey: PublicKey
  if pb.getField(1, pubKey):
    trace "read public key from message", pubKey = ($pubKey).shortLog
    result.pubKey = some(pubKey)

  if pb.getRepeatedField(2, result.addrs):
    trace "read addresses from message", addresses = result.addrs

  if pb.getRepeatedField(3, result.protos):
    trace "read protos from message", protocols = result.protos

  var observableAddr: MultiAddress
  if pb.getField(4, observableAddr):
    trace "read observableAddr from message", address = observableAddr
    result.observedAddr = some(observableAddr)

  var protoVersion = ""
  if pb.getField(5, protoVersion):
    trace "read protoVersion from message", protoVersion = protoVersion
    result.protoVersion = some(protoVersion)

  var agentVersion = ""
  if pb.getField(6, agentVersion):
    trace "read agentVersion from message", agentVersion = agentVersion
    result.agentVersion = some(agentVersion)

proc newIdentify*(peerInfo: PeerInfo): Identify =
  new result
  result.peerInfo = peerInfo
  result.init()

method init*(p: Identify) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    try:
      defer:
        trace "exiting identify handler", oid = conn.oid
        await conn.close()

      trace "handling identify request", oid = conn.oid
      var pb = encodeMsg(p.peerInfo, conn.observedAddr)
      await conn.writeLp(pb.buffer)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in identify handler", exc = exc.msg

  p.handler = handle
  p.codec = IdentifyCodec

proc identify*(p: Identify,
               conn: Connection,
               remotePeerInfo: PeerInfo): Future[IdentifyInfo] {.async, gcsafe.} =
  trace "initiating identify", peer = $conn
  var message = await conn.readLp(64*1024)
  if len(message) == 0:
    trace "identify: Invalid or empty message received!"
    raise newException(IdentityInvalidMsgError,
      "Invalid or empty message received!")

  result = decodeMsg(message)

  if not isNil(remotePeerInfo) and result.pubKey.isSome:
    let peer = PeerID.init(result.pubKey.get())
    if peer.isErr:
      raise newException(IdentityInvalidMsgError, $peer.error)
    else:
      # do a string comaprison of the ids,
      # because that is the only thing we
      # have in most cases
      if peer.get() != remotePeerInfo.peerId:
        trace "Peer ids don't match",
              remote = peer.get().pretty(),
              local = remotePeerInfo.id

        raise newException(IdentityNoMatchError, "Peer ids don't match")

proc push*(p: Identify, conn: Connection) {.async.} =
  await conn.write(IdentifyPushCodec)
  var pb = encodeMsg(p.peerInfo, conn.observedAddr)
  await conn.writeLp(pb.buffer)

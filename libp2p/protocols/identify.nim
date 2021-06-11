## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import options
import chronos, chronicles
import ../protobuf/minprotobuf,
       ../peerinfo,
       ../connmanager,
       ../stream/connection,
       ../peerid,
       ../crypto/crypto,
       ../multiaddress,
       ../protocols/protocol,
       ../utility,
       ../errors

logScope:
  topics = "libp2p identify"

const
  IdentifyCodec* = "/ipfs/id/1.0.0"
  IdentifyPushCodec* = "/ipfs/id/push/1.0.0"
  ProtoVersion* = "ipfs/0.1.0"
  AgentVersion* = "nim-libp2p/0.0.1"

type
  IdentifyError* = object of LPError
  IdentityNoMatchError* = object of IdentifyError
  IdentityInvalidMsgError* = object of IdentifyError
  IdentifyNoPubKeyError* = object of IdentifyError

  IdentifyInfo* = object
    pubKey*: Option[PublicKey]
    addrs*: seq[MultiAddress]
    observedAddr*: Option[MultiAddress]
    protoVersion*: Option[string]
    agentVersion*: Option[string]
    protos*: seq[string]

  Identify* = ref object of LPProtocol
    peerInfo*: PeerInfo

  IdentifyPush* = ref object of LPProtocol
    connManager: ConnManager

proc encodeMsg*(peerInfo: PeerInfo, observedAddr: Multiaddress): ProtoBuffer
  {.raises: [Defect, IdentifyNoPubKeyError].} =
  result = initProtoBuffer()
  if peerInfo.publicKey.isNone:
    raise newException(IdentifyNoPubKeyError, "No public key found for peer!")

  result.write(1, peerInfo.publicKey.get().getBytes().get())
  for ma in peerInfo.addrs:
    result.write(2, ma.data.buffer)
  for proto in peerInfo.protocols:
    result.write(3, proto)
  result.write(4, observedAddr.data.buffer)
  let protoVersion = ProtoVersion
  result.write(5, protoVersion)
  let agentVersion = if peerInfo.agentVersion.len <= 0:
    AgentVersion
  else:
    peerInfo.agentVersion
  result.write(6, agentVersion)
  result.finish()

proc decodeMsg*(buf: seq[byte]): Option[IdentifyInfo] =
  var
    iinfo: IdentifyInfo
    pubKey: PublicKey
    oaddr: MultiAddress
    protoVersion: string
    agentVersion: string

  var pb = initProtoBuffer(buf)

  let r1 = pb.getField(1, pubKey)
  let r2 = pb.getRepeatedField(2, iinfo.addrs)
  let r3 = pb.getRepeatedField(3, iinfo.protos)
  let r4 = pb.getField(4, oaddr)
  let r5 = pb.getField(5, protoVersion)
  let r6 = pb.getField(6, agentVersion)

  let res = r1.isOk() and r2.isOk() and r3.isOk() and
            r4.isOk() and r5.isOk() and r6.isOk()

  if res:
    if r1.get():
      iinfo.pubKey = some(pubKey)
    if r4.get():
      iinfo.observedAddr = some(oaddr)
    if r5.get():
      iinfo.protoVersion = some(protoVersion)
    if r6.get():
      iinfo.agentVersion = some(agentVersion)
    debug "decodeMsg: decoded message", pubkey = ($pubKey).shortLog,
          addresses = $iinfo.addrs, protocols = $iinfo.protos,
          observable_address = $iinfo.observedAddr,
          proto_version = $iinfo.protoVersion,
          agent_version = $iinfo.agentVersion
    some(iinfo)
  else:
    trace "decodeMsg: failed to decode received message"
    none[IdentifyInfo]()

proc new*(T: typedesc[Identify], peerInfo: PeerInfo): T =
  let identify = T(peerInfo: peerInfo)
  identify.init()
  identify

proc newIdentify*(peerInfo: PeerInfo): Identify {.deprecated: "use Identify.new".} =
  Identify.new(peerInfo)

method init*(p: Identify) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    try:
      trace "handling identify request", conn
      var pb = encodeMsg(p.peerInfo, conn.observedAddr)
      await conn.writeLp(pb.buffer)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in identify handler", exc = exc.msg, conn
    finally:
      trace "exiting identify handler", conn
      await conn.closeWithEOF()

  p.handler = handle
  p.codec = IdentifyCodec

proc identify*(p: Identify,
               conn: Connection,
               remotePeerInfo: PeerInfo): Future[IdentifyInfo] {.async, gcsafe.} =
  trace "initiating identify", conn
  var message = await conn.readLp(64*1024)
  if len(message) == 0:
    trace "identify: Empty message received!", conn
    raise newException(IdentityInvalidMsgError, "Empty message received!")

  let infoOpt = decodeMsg(message)
  if infoOpt.isNone():
    raise newException(IdentityInvalidMsgError, "Incorrect message received!")
  result = infoOpt.get()

  if not isNil(remotePeerInfo) and result.pubKey.isSome:
    let peer = PeerID.init(result.pubKey.get())
    if peer.isErr:
      raise newException(IdentityInvalidMsgError, $peer.error)
    else:
      if peer.get() != remotePeerInfo.peerId:
        trace "Peer ids don't match",
              remote = peer,
              local = remotePeerInfo.peerId

        raise newException(IdentityNoMatchError, "Peer ids don't match")

proc new*(T: typedesc[IdentifyPush], connManager: ConnManager): T =
  let identifypush = T(connManager: connManager)
  identifypush.init()
  identifypush


proc init*(p: IdentifyPush) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    trace "handling identify push", conn
    try:
      var message = await conn.readLp(64*1024)

      let infoOpt = decodeMsg(message)
      if infoOpt.isNone():
        raise newException(IdentityInvalidMsgError, "Incorrect message received!")

      let indentInfo = infoOpt.get()

      if isNil(conn.peerInfo):
        raise newException(IdentityInvalidMsgError, "Connection got no peerInfo")

      if indentInfo.pubKey.isSome:
        let receivedPeerId = PeerID.init(indentInfo.pubKey.get()).tryGet()
        if receivedPeerId != conn.peerInfo.peerId:
          raise newException(IdentityNoMatchError, "Peer ids don't match")

      if indentInfo.addrs.len > 0:
        conn.peerInfo.addrs = indentInfo.addrs

      if indentInfo.agentVersion.isSome:
        conn.peerInfo.agentVersion = indentInfo.agentVersion.get()

      if indentInfo.protoVersion.isSome:
        conn.peerInfo.protoVersion = indentInfo.protoVersion.get()

      if indentInfo.protos.len > 0:
        conn.peerInfo.protocols = indentInfo.protos

      trace "triggering peer event", peerInfo = conn.peerInfo
      await p.connManager.triggerPeerEvents(conn.peerInfo, PeerEvent(kind: PeerEventKind.Identified))
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      info "exception in identify push handler", exc = exc.msg, conn
    finally:
      trace "exiting identify push handler", conn
      await conn.closeWithEOF()

  p.handler = handle
  p.codec = IdentifyPushCodec

proc push*(p: IdentifyPush, peerInfo: PeerInfo, conn: Connection) {.async.} =
  var pb = encodeMsg(peerInfo, conn.observedAddr)
  await conn.writeLp(pb.buffer)

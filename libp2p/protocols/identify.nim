# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## `Identify <https://docs.libp2p.io/concepts/protocols/#identify>`_ and
## `Push Identify <https://docs.libp2p.io/concepts/protocols/#identify-push>`_ implementation

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[sequtils, options, strutils, sugar]
import stew/results
import chronos, chronicles
import ../protobuf/minprotobuf,
       ../peerinfo,
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

  IdentifyInfo* {.public.} = object
    pubkey*: Option[PublicKey]
    peerId*: PeerId
    addrs*: seq[MultiAddress]
    observedAddr*: Option[MultiAddress]
    protoVersion*: Option[string]
    agentVersion*: Option[string]
    protos*: seq[string]
    signedPeerRecord*: Option[Envelope]

  Identify* = ref object of LPProtocol
    peerInfo*: PeerInfo
    sendSignedPeerRecord*: bool

  IdentifyPushHandler* = proc (
    peer: PeerId,
    newInfo: IdentifyInfo):
    Future[void]
    {.gcsafe, raises: [Defect], public.}

  IdentifyPush* = ref object of LPProtocol
    identifyHandler: IdentifyPushHandler

chronicles.expandIt(IdentifyInfo):
  pubkey = ($it.pubkey).shortLog
  addresses = it.addrs.map(x => $x).join(",")
  protocols = it.protos.map(x => $x).join(",")
  observable_address =
    if it.observedAddr.isSome(): $it.observedAddr.get()
    else: "None"
  proto_version = it.protoVersion.get("None")
  agent_version = it.agentVersion.get("None")
  signedPeerRecord =
    # The SPR contains the same data as the identify message
    # would be cumbersome to log
    if iinfo.signedPeerRecord.isSome(): "Some"
    else: "None"

proc encodeMsg(peerInfo: PeerInfo, observedAddr: Opt[MultiAddress], sendSpr: bool): ProtoBuffer
  {.raises: [Defect].} =
  result = initProtoBuffer()

  let pkey = peerInfo.publicKey

  result.write(1, pkey.getBytes().get())
  for ma in peerInfo.addrs:
    result.write(2, ma.data.buffer)
  for proto in peerInfo.protocols:
    result.write(3, proto)
  if observedAddr.isSome:
    result.write(4, observedAddr.get().data.buffer)
  let protoVersion = ProtoVersion
  result.write(5, protoVersion)
  let agentVersion = if peerInfo.agentVersion.len <= 0:
    AgentVersion
  else:
    peerInfo.agentVersion
  result.write(6, agentVersion)

  ## Optionally populate signedPeerRecord field.
  ## See https://github.com/libp2p/go-libp2p/blob/ddf96ce1cfa9e19564feb9bd3e8269958bbc0aba/p2p/protocol/identify/pb/identify.proto for reference.
  if sendSpr:
    let sprBuff = peerInfo.signedPeerRecord.envelope.encode()
    if sprBuff.isOk():
      result.write(8, sprBuff.get())

  result.finish()

proc decodeMsg*(buf: seq[byte]): Option[IdentifyInfo] =
  var
    iinfo: IdentifyInfo
    pubkey: PublicKey
    oaddr: MultiAddress
    protoVersion: string
    agentVersion: string
    signedPeerRecord: SignedPeerRecord

  var pb = initProtoBuffer(buf)

  let r1 = pb.getField(1, pubkey)
  let r2 = pb.getRepeatedField(2, iinfo.addrs)
  let r3 = pb.getRepeatedField(3, iinfo.protos)
  let r4 = pb.getField(4, oaddr)
  let r5 = pb.getField(5, protoVersion)
  let r6 = pb.getField(6, agentVersion)

  let r8 = pb.getField(8, signedPeerRecord)

  let res = r1.isOk() and r2.isOk() and r3.isOk() and
            r4.isOk() and r5.isOk() and r6.isOk() and
            r8.isOk()

  if res:
    if r1.get():
      iinfo.pubkey = some(pubkey)
    if r4.get():
      iinfo.observedAddr = some(oaddr)
    if r5.get():
      iinfo.protoVersion = some(protoVersion)
    if r6.get():
      iinfo.agentVersion = some(agentVersion)
    if r8.get() and r1.get():
      if iinfo.pubkey.get() == signedPeerRecord.envelope.publicKey:
        iinfo.signedPeerRecord = some(signedPeerRecord.envelope)
    debug "decodeMsg: decoded identify", iinfo
    some(iinfo)
  else:
    trace "decodeMsg: failed to decode received message"
    none[IdentifyInfo]()

proc new*(
  T: typedesc[Identify],
  peerInfo: PeerInfo,
  sendSignedPeerRecord = false
  ): T =
  let identify = T(
    peerInfo: peerInfo,
    sendSignedPeerRecord: sendSignedPeerRecord
  )
  identify.init()
  identify

method init*(p: Identify) =
  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    try:
      trace "handling identify request", conn
      var pb = encodeMsg(p.peerInfo, conn.observedAddr, p.sendSignedPeerRecord)
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
               remotePeerId: PeerId): Future[IdentifyInfo] {.async, gcsafe.} =
  trace "initiating identify", conn
  var message = await conn.readLp(64*1024)
  if len(message) == 0:
    trace "identify: Empty message received!", conn
    raise newException(IdentityInvalidMsgError, "Empty message received!")

  let infoOpt = decodeMsg(message)
  if infoOpt.isNone():
    raise newException(IdentityInvalidMsgError, "Incorrect message received!")
  result = infoOpt.get()

  if result.pubkey.isSome:
    let peer = PeerId.init(result.pubkey.get())
    if peer.isErr:
      raise newException(IdentityInvalidMsgError, $peer.error)
    else:
      result.peerId = peer.get()
      if peer.get() != remotePeerId:
        trace "Peer ids don't match",
              remote = peer,
              local = remotePeerId

        raise newException(IdentityNoMatchError, "Peer ids don't match")
  else:
    raise newException(IdentityInvalidMsgError, "No pubkey in identify")

proc new*(T: typedesc[IdentifyPush], handler: IdentifyPushHandler = nil): T {.public.} =
  ## Create a IdentifyPush protocol. `handler` will be called every time
  ## a peer sends us new `PeerInfo`
  let identifypush = T(identifyHandler: handler)
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

      var indentInfo = infoOpt.get()

      if indentInfo.pubkey.isSome:
        let receivedPeerId = PeerId.init(indentInfo.pubkey.get()).tryGet()
        if receivedPeerId != conn.peerId:
          raise newException(IdentityNoMatchError, "Peer ids don't match")
        indentInfo.peerId = receivedPeerId

      trace "triggering peer event", peerInfo = conn.peerId
      if not isNil(p.identifyHandler):
        await p.identifyHandler(conn.peerId, indentInfo)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      info "exception in identify push handler", exc = exc.msg, conn
    finally:
      trace "exiting identify push handler", conn
      await conn.closeWithEOF()

  p.handler = handle
  p.codec = IdentifyPushCodec

proc push*(p: IdentifyPush, peerInfo: PeerInfo, conn: Connection) {.async, public.} =
  ## Send new `peerInfo`s to a connection
  var pb = encodeMsg(peerInfo, conn.observedAddr, true)
  await conn.writeLp(pb.buffer)

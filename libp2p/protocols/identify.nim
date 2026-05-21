# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## `Identify <https://docs.libp2p.io/concepts/protocols/#identify>`_ and
## `Push Identify <https://docs.libp2p.io/concepts/protocols/#identify-push>`_ implementation

{.push raises: [].}

import std/strutils
import results, chronos, chronicles
import
  ../protobuf/minprotobuf,
  ../peerinfo,
  ../stream/connection,
  ../peerid,
  ../crypto/crypto,
  ../multiaddress,
  ../multicodec,
  ../protocols/protocol,
  ../utility,
  ../errors,
  ../observedaddrmanager

export observedaddrmanager

logScope:
  topics = "libp2p identify"

const
  IdentifyCodec* = "/ipfs/id/1.0.0"
  IdentifyPushCodec* = "/ipfs/id/push/1.0.0"
  ProtoVersion* = "ipfs/0.1.0"
  AgentVersion* = "nim-libp2p"
  identifyAddrsLogMax = 5
  maxMsgSize = 64 * 1024

type
  IdentifyError* = object of LPError
  IdentityNoMatchError* = object of IdentifyError
  IdentityInvalidMsgError* = object of IdentifyError
  IdentifyNoPubKeyError* = object of IdentifyError

  IdentifyInfo* = object
    pubkey*: Opt[PublicKey]
    peerId*: PeerId
    addrs*: seq[MultiAddress]
    observedAddr*: Opt[MultiAddress]
    protoVersion*: Opt[string]
    agentVersion*: Opt[string]
    protos*: seq[string]
    signedPeerRecord*: Opt[Envelope]

  Identify* = ref object of LPProtocol
    peerInfo*: PeerInfo
    sendSignedPeerRecord*: bool
    observedAddrManager*: ObservedAddrManager

  IdentifyPushHandler* =
    proc(peer: PeerId, newInfo: IdentifyInfo): Future[void] {.gcsafe, raises: [].}

  IdentifyPush* = ref object of LPProtocol
    identifyHandler: IdentifyPushHandler

chronicles.expandIt(IdentifyInfo):
  pubkey = ($it.pubkey).shortLog
  addresses = it.addrs.shortLog(identifyAddrsLogMax)
  protocols = it.protos.join(",")
  observable_address = $it.observedAddr
  proto_version = it.protoVersion.get("None")
  agent_version = it.agentVersion.get("None")
  signedPeerRecord =
    # The SPR contains the same data as the identify message
    # would be cumbersome to log
    if it.signedPeerRecord.isSome(): "Some" else: "None"

proc encodeMsg(
    peerInfo: PeerInfo, observedAddr: Opt[MultiAddress], sendSpr: bool
): ProtoBuffer {.raises: [].} =
  result = initProtoBuffer()

  let pkey = peerInfo.publicKey

  result.write(1, pkey.getBytes().expect("valid key"))
  for ma in peerInfo.addrs:
    result.write(2, ma.data.buffer)
  for proto in peerInfo.protocols:
    result.write(3, proto)
  observedAddr.withValue(observed):
    result.write(4, observed.data.buffer)
  result.write(5, ProtoVersion)
  let agentVersion =
    if peerInfo.agentVersion.len <= 0: AgentVersion else: peerInfo.agentVersion
  result.write(6, agentVersion)

  ## Optionally populate signedPeerRecord field.
  ## See https://github.com/libp2p/go-libp2p/blob/ddf96ce1cfa9e19564feb9bd3e8269958bbc0aba/p2p/protocol/identify/pb/identify.proto for reference.
  if sendSpr:
    peerInfo.signedPeerRecord.envelope.encode().toOpt().withValue(sprBuff):
      result.write(8, sprBuff)

  result.finish()

proc decodeMsg*(buf: sink seq[byte]): Opt[IdentifyInfo] =
  var
    iinfo: IdentifyInfo
    pubkey: PublicKey
    oaddr: MultiAddress
    protoVersion: string
    agentVersion: string
    signedPeerRecord: SignedPeerRecord

  var pb = initProtoBuffer(move(buf))
  if ?pb.getField(1, pubkey).toOpt():
    iinfo.pubkey = Opt.some(pubkey)
    if ?pb.getField(8, signedPeerRecord).toOpt() and
        pubkey == signedPeerRecord.envelope.publicKey:
      iinfo.signedPeerRecord = Opt.some(signedPeerRecord.envelope)
  discard ?pb.getRepeatedField(2, iinfo.addrs).toOpt()
  discard ?pb.getRepeatedField(3, iinfo.protos).toOpt()
  if ?pb.getField(4, oaddr).toOpt():
    iinfo.observedAddr = Opt.some(oaddr)
  if ?pb.getField(5, protoVersion).toOpt():
    iinfo.protoVersion = Opt.some(protoVersion)
  if ?pb.getField(6, agentVersion).toOpt():
    iinfo.agentVersion = Opt.some(agentVersion)

  Opt.some(iinfo)

proc new*(
    T: typedesc[Identify],
    peerInfo: PeerInfo,
    sendSignedPeerRecord = false,
    observedAddrManager = ObservedAddrManager.new(),
): T =
  let identify = T(
    peerInfo: peerInfo,
    sendSignedPeerRecord: sendSignedPeerRecord,
    observedAddrManager: observedAddrManager,
  )
  identify.init()
  identify

method init*(p: Identify) =
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    try:
      trace "handling identify request", stream
      let pb = encodeMsg(p.peerInfo, stream.observedAddr, p.sendSignedPeerRecord)
      await stream.writeLp(pb.buffer)
      debug "identify: info sent", stream, info = p.peerInfo
    except CancelledError as exc:
      trace "cancelled identify handler"
      raise exc
    except CatchableError as exc:
      trace "exception in identify handler", description = exc.msg, stream
    finally:
      trace "exiting identify handler", stream
      await stream.closeWithEOF()

  p.handler = handle
  p.codec = IdentifyCodec

proc identify*(
    self: Identify, stream: Stream, remotePeerId: PeerId
): Future[IdentifyInfo] {.
    async: (
      raises:
        [IdentityInvalidMsgError, IdentityNoMatchError, LPStreamError, CancelledError]
    )
.} =
  trace "initiating identify", stream
  var message = await stream.readLp(maxMsgSize)
  if len(message) == 0:
    trace "identify: Empty message received!", stream
    raise newException(IdentityInvalidMsgError, "Empty message received!")

  var info = decodeMsg(move(message)).valueOr:
    raise newException(IdentityInvalidMsgError, "Incorrect message received!")
  debug "identify: info received", stream, info
  let
    pubkey = info.pubkey.valueOr:
      raise newException(IdentityInvalidMsgError, "No pubkey in identify")
    peer = PeerId.init(pubkey).valueOr:
      raise newException(IdentityInvalidMsgError, $error)

  if peer != remotePeerId:
    trace "Peer ids don't match", remote = peer, local = remotePeerId
    raise newException(IdentityNoMatchError, "Peer ids don't match")
  info.peerId = peer

  info.observedAddr.withValue(observed):
    # Currently, we use the ObservedAddrManager only to find our dialable external NAT address. Therefore, addresses
    # like "...\p2p-circuit\p2p\..." and "\p2p\..." are not useful to us.
    if observed.contains(multiCodec("p2p-circuit")).get(false) or
        P2PPattern.matchPartial(observed):
      trace "Not adding address to ObservedAddrManager.", observed
    elif not self.observedAddrManager.addObservation(observed):
      trace "Observed address is not valid.", observedAddr = observed
  return info

proc new*(T: typedesc[IdentifyPush], handler: IdentifyPushHandler = nil): T =
  ## Create a IdentifyPush protocol. `handler` will be called every time
  ## a peer sends us new `PeerInfo`
  let identifypush = T(identifyHandler: handler)
  identifypush.init()
  identifypush

proc init*(p: IdentifyPush) =
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    trace "handling identify push", stream
    try:
      var message = await stream.readLp(maxMsgSize)

      var identInfo = decodeMsg(move(message)).valueOr:
        raise newException(IdentityInvalidMsgError, "Incorrect message received!")
      debug "identify push: info received", stream, identInfo

      identInfo.pubkey.withValue(pubkey):
        let receivedPeerId = PeerId.init(pubkey).tryGet()
        if receivedPeerId != stream.peerId:
          raise newException(IdentityNoMatchError, "Peer ids don't match")
        identInfo.peerId = receivedPeerId
      else:
        identInfo.peerId = stream.peerId

      trace "triggering peer event", peerInfo = stream.peerId
      if not isNil(p.identifyHandler):
        await p.identifyHandler(stream.peerId, identInfo)
    except CancelledError as exc:
      trace "cancelled identify push handler"
      raise exc
    except CatchableError as exc:
      info "exception in identify push handler", description = exc.msg, stream
    finally:
      trace "exiting identify push handler", stream
      await stream.closeWithEOF()

  p.handler = handle
  p.codec = IdentifyPushCodec

proc push*(
    p: IdentifyPush, peerInfo: PeerInfo, stream: Stream
) {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Send new `peerInfo`s to a connection
  let pb = encodeMsg(peerInfo, stream.observedAddr, true)
  await stream.writeLp(pb.buffer)

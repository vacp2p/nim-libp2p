# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## `Identify <https://docs.libp2p.io/concepts/protocols/#identify>`_ and
## `Push Identify <https://docs.libp2p.io/concepts/protocols/#identify-push>`_ implementation

{.push raises: [].}

import std/strutils
import results, chronos, chronicles
import protobuf_serialization, protobuf_serialization/pkg/results
import
  ../peerinfo,
  ../stream/connection,
  ../peerid,
  ../crypto/crypto,
  ../multiaddress,
  ../multicodec,
  ../protocols/protocol,
  ../utils/[opt, protobuf],
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

  Delta* {.proto2.} = object
    addedProtocols* {.fieldNumber: 1.}: seq[string]
    removedProtocols* {.fieldNumber: 2.}: seq[string]

  IdentifyMsg {.proto2.} = object
    publicKey* {.fieldNumber: 1, ext.}: Opt[PublicKey]
    listenAddrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]
    protocols* {.fieldNumber: 3.}: seq[string]
    observedAddr* {.fieldNumber: 4, ext.}: Opt[MultiAddress]
    protoVersion* {.fieldNumber: 5.}: Opt[string]
    agentVersion* {.fieldNumber: 6.}: Opt[string]
    delta* {.fieldNumber: 7.}: Opt[Delta]
    signedPeerRecord* {.fieldNumber: 8.}: Opt[seq[byte]]

  IdentifyInfo* = object
    peerId*: PeerId
    pubkey*: Opt[PublicKey]
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
    proc(newInfo: IdentifyInfo): Future[void] {.gcsafe, raises: [].}

  IdentifyPush* = ref object of LPProtocol
    identifyHandler: IdentifyPushHandler

Protobuf.serializerFor([IdentifyMsg], withMetrics = true, domain = "identify")

chronicles.expandIt(IdentifyMsg):
  pubkey = ($it.publicKey).shortLog
  addresses = it.listenAddrs.shortLog(identifyAddrsLogMax)
  protocols = it.protocols.join(",")
  observable_address = $it.observedAddr
  proto_version = it.protoVersion.get("None")
  agent_version = it.agentVersion.get("None")
  signedPeerRecord = if it.signedPeerRecord.isSome: "Some" else: "None"

proc makeIdentifyMsg(
    pi: PeerInfo, observedAddr: Opt[MultiAddress], sign: bool
): IdentifyMsg =
  var spr = Opt.none(seq[byte])
  ## Optionally populate signedPeerRecord field.
  ## See https://github.com/libp2p/go-libp2p/blob/ddf96ce1cfa9e19564feb9bd3e8269958bbc0aba/p2p/protocol/identify/pb/identify.proto for reference.
  if sign:
    spr = Opt.some(pi.signedPeerRecord.envelope.encode())

  IdentifyMsg(
    publicKey: Opt.some(pi.publicKey),
    listenAddrs: pi.addrs,
    protocols: pi.protocols,
    observedAddr: observedAddr,
    protoVersion: Opt.some(ProtoVersion),
    agentVersion: Opt.some(if pi.agentVersion == "": AgentVersion else: pi.agentVersion),
    signedPeerRecord: spr,
  )

proc makeIdentifyInfo(peer: PeerId, msg: IdentifyMsg): IdentifyInfo =
  var spr = Opt.none(Envelope)
  msg.signedPeerRecord.withValue(sprBytes):
    SignedPeerRecord.decode(sprBytes).toOpt().withValue(signedPeerRecord):
      if signedPeerRecord.data.peerId == peer:
        spr = Opt.some(signedPeerRecord.envelope)

  IdentifyInfo(
    peerId: peer,
    pubkey: msg.publicKey,
    addrs: msg.listenAddrs,
    protos: msg.protocols,
    observedAddr: msg.observedAddr,
    protoVersion: msg.protoVersion,
    agentVersion: msg.agentVersion,
    signedPeerRecord: spr,
  )

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
    trace "handling identify request", stream

    let msg = makeIdentifyMsg(p.peerInfo, stream.observedAddr, p.sendSignedPeerRecord)
    try:
      await stream.writeLp(msg.encode())
      debug "identify: info sent", stream, info = p.peerInfo
    except LPError as e:
      trace "identify handler failed to write message", description = e.msg, stream
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
  if message.len == 0:
    trace "identify: Empty message received!", stream
    raise newException(IdentityInvalidMsgError, "Empty message received")

  var identifyMsg = IdentifyMsg.decode(move message).valueOr:
    raise newException(IdentityInvalidMsgError, error)

  debug "identify: info received", stream, identifyMsg

  let
    pubkey = identifyMsg.publicKey.valueOr:
      raise newException(IdentityInvalidMsgError, "No pubkey in identify")
    peer = PeerId.init(pubkey).valueOr:
      raise newException(IdentityInvalidMsgError, $error)

  if peer != remotePeerId:
    trace "Peer ids don't match", remote = peer, local = remotePeerId
    raise newException(IdentityNoMatchError, "Peer ids don't match")

  identifyMsg.observedAddr.withValue(observed):
    # Currently, we use the ObservedAddrManager only to find our dialable external NAT address. Therefore, addresses
    # like "...\p2p-circuit\p2p\..." and "\p2p\..." are not useful to us.
    if observed.contains(multiCodec("p2p-circuit")).get(false) or
        P2PPattern.matchPartial(observed):
      trace "Not adding address to ObservedAddrManager.", observed
    elif not self.observedAddrManager.addObservation(observed):
      trace "Observed address is not valid.", observedAddr = observed

  return makeIdentifyInfo(peer, identifyMsg)

proc new*(T: typedesc[IdentifyPush], handler: IdentifyPushHandler = nil): T =
  ## Create a IdentifyPush protocol. `handler` will be called every time
  ## a peer sends us new `PeerInfo`
  let identifypush = T(identifyHandler: handler)
  identifypush.init()
  identifypush

proc init*(p: IdentifyPush) =
  proc handle(stream: Stream, proto: string) {.async: (raises: [CancelledError]).} =
    trace "handling identify push", stream
    defer:
      await stream.closeWithEOF()

    var message =
      try:
        await stream.readLp(maxMsgSize)
      except LPError as e:
        info "failed to read message from stream", description = e.msg, stream
        return

    let identifyMsg = IdentifyMsg.decode(move message).valueOr:
      info "failed to decode identify message", error, stream
      return

    debug "identify push: info received", stream, identifyMsg

    var peerId: PeerId
    identifyMsg.publicKey.withValue(pubkey):
      let receivedPeerId = PeerId.init(pubkey).valueOr:
        debug "could not create PeerId from pubkey", stream
        return
      if receivedPeerId != stream.peerId:
        info "Peer ids don't match", stream
        return
      peerId = receivedPeerId
    else:
      peerId = stream.peerId

    let handler = p.identifyHandler
    if not handler.isNil:
      trace "triggering peer event", peerInfo = stream.peerId
      try:
        await handler(makeIdentifyInfo(peerId, identifyMsg))
      except CancelledError as e:
        raise e
      except CatchableError as e:
        warn "got unexpected error", description = e.msg, stream
        # compiler reports strange CatchableError error that should never really happen
        discard

  p.handler = handle
  p.codec = IdentifyPushCodec

proc push*(
    p: IdentifyPush, peerInfo: PeerInfo, stream: Stream
) {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Send new `peerInfo`s to a connection
  let msg = makeIdentifyMsg(peerInfo, stream.observedAddr, true)
  await stream.writeLp(msg.encode())

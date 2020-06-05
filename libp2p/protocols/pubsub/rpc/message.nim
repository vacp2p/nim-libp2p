## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import chronicles
import metrics
import nimcrypto/sysrand
import messages, protobuf,
       ../../../peer,
       ../../../peerinfo,
       ../../../crypto/crypto,
       ../../../protobuf/minprotobuf

logScope:
  topic = "PubSubMessage"

const PubSubPrefix = "libp2p-pubsub:"

declareGauge(libp2p_pubsub_sig_verify_success, "pubsub successfully validated messages")
declareGauge(libp2p_pubsub_sig_verify_failure, "pubsub failed validated messages")

proc msgIdProvider(m: Message): string =
  ## default msg id provider
  m.seqno.toHex() & PeerID.init(m.fromPeer).pretty

template msgId*(m: Message): string =
  ## calls the ``msgIdProvider`` from
  ## the instantiation scope
  ##
  mixin msgIdProvider
  m.msgIdProvider()

proc fromPeerId*(m: Message): PeerId =
  PeerID.init(m.fromPeer)

proc sign*(msg: Message, p: PeerInfo): Message {.gcsafe.} =
  var buff = initProtoBuffer()
  encodeMessage(msg, buff)
  if buff.buffer.len > 0:
    result = msg
    result.signature = p.privateKey.
                       sign(cast[seq[byte]](PubSubPrefix) & buff.buffer).tryGet().
                       getBytes()

proc verify*(m: Message, p: PeerInfo): bool =
  if m.signature.len > 0 and m.key.len > 0:
    var msg = m
    msg.signature = @[]
    msg.key = @[]

    var buff = initProtoBuffer()
    encodeMessage(msg, buff)

    var remote: Signature
    var key: PublicKey
    if remote.init(m.signature) and key.init(m.key):
      trace "verifying signature", remoteSignature = remote
      result = remote.verify(cast[seq[byte]](PubSubPrefix) & buff.buffer, key)
  
  if result:
    libp2p_pubsub_sig_verify_success.inc()
  else:
    libp2p_pubsub_sig_verify_failure.inc()

proc newMessage*(p: PeerInfo,
                 data: seq[byte],
                 topic: string,
                 sign: bool = true): Message {.gcsafe.} =
  var seqno: seq[byte] = newSeq[byte](8)
  if randomBytes(addr seqno[0], 8) > 0:
    if p.publicKey.isSome:
      var key: seq[byte] = p.publicKey.get().getBytes().tryGet()

      result = Message(fromPeer: p.peerId.getBytes(),
                      data: data,
                      seqno: seqno,
                      topicIDs: @[topic])
      if sign:
        result = result.sign(p)

      result.key = key

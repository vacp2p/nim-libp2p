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
import chronicles, stew/byteutils
import metrics
import chronicles
import nimcrypto/sysrand
import messages, protobuf,
       ../../../peer,
       ../../../peerinfo,
       ../../../crypto/crypto,
       ../../../protobuf/minprotobuf

logScope:
  topics = "pubsubmessage"

const PubSubPrefix = toBytes("libp2p-pubsub:")

declareCounter(libp2p_pubsub_sig_verify_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_sig_verify_failure, "pubsub failed validated messages")

func defaultMsgIdProvider*(m: Message): string =
  byteutils.toHex(m.seqno) & m.fromPeer.pretty

proc sign*(msg: Message, p: PeerInfo): seq[byte] {.gcsafe, raises: [ResultError[CryptoError], Defect].} =
  var buff = initProtoBuffer()
  encodeMessage(msg, buff)
  p.privateKey.sign(PubSubPrefix & buff.buffer).tryGet().getBytes()

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
      result = remote.verify(PubSubPrefix & buff.buffer, key)

  if result:
    libp2p_pubsub_sig_verify_success.inc()
  else:
    libp2p_pubsub_sig_verify_failure.inc()

proc init*(
    T: type Message,
    p: PeerInfo,
    data: seq[byte],
    topic: string,
    sign: bool = true): Message {.gcsafe, raises: [CatchableError, Defect].} =
  var seqno: seq[byte] = newSeq[byte](8)
  if randomBytes(addr seqno[0], 8) <= 0:
    raise (ref CatchableError)(msg: "Cannot get randomness for message")

  result = Message(
    fromPeer: p.peerId,
    data: data,
    seqno: seqno,
    topicIDs: @[topic])

  if sign and p.publicKey.isSome:
    result.signature = sign(result, p)
    result.key =  p.publicKey.get().getBytes().tryGet()

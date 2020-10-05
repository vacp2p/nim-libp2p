## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import hashes
import chronicles, metrics, stew/[byteutils, endians2]
import ./messages,
       ./protobuf,
       ../../../peerid,
       ../../../peerinfo,
       ../../../crypto/crypto,
       ../../../protobuf/minprotobuf

export messages

logScope:
  topics = "pubsubmessage"

const PubSubPrefix = toBytes("libp2p-pubsub:")

declareCounter(libp2p_pubsub_sig_verify_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_sig_verify_failure, "pubsub failed validated messages")

func defaultMsgIdProvider*(m: Message): MessageID =
  var res: seq[byte]
  if m.seqno.len > 0 and m.fromPeer.data.len > 0:
    res &= m.seqno
    res &= m.fromPeer.data
  else:
    var
      dataHash = m.data.hash
      topicHash = m.topicIDs.hash
      bDataHash = cast[ptr UncheckedArray[byte]](addr dataHash)
      bTopicHash = cast[ptr UncheckedArray[byte]](addr topicHash)
    res &= bDataHash.toOpenArray(0, sizeof(Hash) - 1)
    res &= bTopicHash.toOpenArray(0, sizeof(Hash) - 1)
  res

proc sign*(msg: Message, privateKey: PrivateKey): CryptoResult[seq[byte]] =
  ok((? privateKey.sign(PubSubPrefix & encodeMessage(msg, false))).getBytes())

proc verify*(m: Message): bool =
  if m.signature.len > 0 and m.key.len > 0:
    var msg = m
    msg.signature = @[]
    msg.key = @[]

    var remote: Signature
    var key: PublicKey
    if remote.init(m.signature) and key.init(m.key):
      trace "verifying signature", remoteSignature = remote
      result = remote.verify(PubSubPrefix & encodeMessage(msg, false), key)

  if result:
    libp2p_pubsub_sig_verify_success.inc()
  else:
    libp2p_pubsub_sig_verify_failure.inc()

proc init*(
    T: type Message,
    peer: Option[PeerInfo],
    data: seq[byte],
    topic: string,
    seqno: Option[uint64],
    sign: bool = true): Message {.gcsafe, raises: [CatchableError, Defect].} =
  var msg = Message(data: data, topicIDs: @[topic])

  # order matters, we want to include seqno in the signature
  if seqno.isSome:
    msg.seqno = @(seqno.get().toBytesBE())

  if peer.isSome:
    let peer = peer.get()
    msg.fromPeer = peer.peerId
    if sign:
      if peer.keyType != KeyType.HasPrivate:
        raise (ref CatchableError)(msg: "Cannot sign message without private key")
      msg.signature = sign(msg, peer.privateKey).tryGet()
      msg.key = peer.privateKey.getKey().tryGet().getBytes().tryGet()
  elif sign:
    raise (ref CatchableError)(msg: "Cannot sign message without peer info")

  msg

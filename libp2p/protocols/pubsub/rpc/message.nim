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
       ../../../protobuf/minprotobuf,
       ../../../protocols/pubsub/errors

export errors, messages

logScope:
  topics = "pubsubmessage"

const PubSubPrefix = toBytes("libp2p-pubsub:")

declareCounter(libp2p_pubsub_sig_verify_success, "pubsub successfully validated messages")
declareCounter(libp2p_pubsub_sig_verify_failure, "pubsub failed validated messages")

func defaultMsgIdProvider*(m: Message): Result[MessageID, ValidationResult] =
  if m.seqno.len > 0 and m.fromPeer.data.len > 0:
    let mid = byteutils.toHex(m.seqno) & $m.fromPeer
    ok mid.toBytes()
  else:
    err ValidationResult.Reject

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
    sign: bool = true): Message
    {.gcsafe, raises: [Defect, LPError].} =
  var msg = Message(data: data, topicIDs: @[topic])

  # order matters, we want to include seqno in the signature
  if seqno.isSome:
    msg.seqno = @(seqno.get().toBytesBE())

  if peer.isSome:
    let peer = peer.get()
    msg.fromPeer = peer.peerId
    if sign:
      msg.signature = sign(msg, peer.privateKey).expect("Couldn't sign message!")
      msg.key = peer.privateKey.getPublicKey().expect("Invalid private key!")
        .getBytes().expect("Couldn't get public key bytes!")
  elif sign:
    raise (ref LPError)(msg: "Cannot sign message without peer info")

  msg

proc init*(
    T: type Message,
    peerId: PeerId,
    data: seq[byte],
    topic: string,
    seqno: Option[uint64]): Message
    {.gcsafe, raises: [Defect, LPError].} =
  var msg = Message(data: data, topicIDs: @[topic])
  msg.fromPeer = peerId

  if seqno.isSome:
    msg.seqno = @(seqno.get().toBytesBE())
  msg

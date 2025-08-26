# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronicles, metrics, stew/[byteutils, endians2]
import
  ./messages,
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

declareCounter(
  libp2p_pubsub_sig_verify_success, "pubsub successfully validated messages"
)
declareCounter(libp2p_pubsub_sig_verify_failure, "pubsub failed validated messages")

func defaultMsgIdProvider*(m: Message): Result[MessageId, ValidationResult] =
  if m.seqno.len > 0 and m.fromPeer.data.len > 0:
    let mid = byteutils.toHex(m.seqno) & $m.fromPeer
    ok mid.toBytes()
  else:
    err ValidationResult.Reject

proc sign*(msg: Message, privateKey: PrivateKey): CryptoResult[seq[byte]] =
  ok((?privateKey.sign(PubSubPrefix & encodeMessage(msg, false))).getBytes())

proc extractPublicKey(m: Message): Opt[PublicKey] =
  var pubkey: PublicKey
  if m.fromPeer.hasPublicKey() and m.fromPeer.extractPublicKey(pubkey):
    Opt.some(pubkey)
  elif m.key.len > 0 and pubkey.init(m.key):
    # check if peerId extracted from m.key is the same as m.fromPeer
    let derivedPeerId = PeerId.init(pubkey).valueOr:
      warn "could not derive peerId from key field"
      return Opt.none(PublicKey)

    if derivedPeerId != m.fromPeer:
      warn "peerId derived from msg.key is not the same as msg.fromPeer",
        derivedPeerId = derivedPeerId, fromPeer = m.fromPeer
      return Opt.none(PublicKey)
    Opt.some(pubkey)
  else:
    Opt.none(PublicKey)

proc verify*(m: Message): bool =
  if m.signature.len > 0:
    var msg = m
    msg.signature = @[]
    msg.key = @[]

    var remote: Signature
    let key = m.extractPublicKey().valueOr:
      warn "could not extract public key", msg = m
      return false

    if remote.init(m.signature):
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
    sign: bool = true,
): Message {.gcsafe, raises: [].} =
  if sign and peer.isNone():
    doAssert(false, "Cannot sign message without peer info")

  var msg = Message(data: data, topic: topic)

  # order matters, we want to include seqno in the signature
  seqno.withValue(seqn):
    msg.seqno = @(seqn.toBytesBE())

  peer.withValue(peer):
    msg.fromPeer = peer.peerId
    if sign:
      msg.signature = sign(msg, peer.privateKey).expect("Couldn't sign message!")
      msg.key = peer.privateKey
        .getPublicKey()
        .expect("Invalid private key!")
        .getBytes()
        .expect("Couldn't get public key bytes!")

  msg

proc init*(
    T: type Message,
    peerId: PeerId,
    data: seq[byte],
    topic: string,
    seqno: Option[uint64],
): Message {.gcsafe, raises: [LPError].} =
  var msg = Message(data: data, topic: topic)
  msg.fromPeer = peerId

  seqno.withValue(seqn):
    msg.seqno = @(seqn.toBytesBE())
  msg

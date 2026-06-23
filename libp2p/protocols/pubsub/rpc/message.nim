# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronicles, metrics, stew/[byteutils, endians2]
import
  ./messages,
  ./protobuf,
  ../../../peerid,
  ../../../peerinfo,
  ../../../crypto/crypto,
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
  if m.seqno.isSome and m.fromPeer.isSome:
    let mid = byteutils.toHex(m.seqno.get()) & $m.fromPeer.get()
    ok mid.toBytes()
  else:
    err ValidationResult.Reject

proc sign*(msg: Message, privateKey: PrivateKey): CryptoResult[seq[byte]] =
  ok((?privateKey.sign(PubSubPrefix & msg.encode(false))).getBytes())

proc extractPublicKey(m: Message): Opt[PublicKey] =
  var pubkey: PublicKey
  if m.fromPeer.isSome and m.fromPeer.get().hasPublicKey() and
      m.fromPeer.get().extractPublicKey(pubkey):
    Opt.some(pubkey)
  elif m.key.isSome and pubkey.init(m.key.get()):
    # check if peerId extracted from m.key is the same as m.fromPeer
    let derivedPeerId = PeerId.init(pubkey).valueOr:
      warn "could not derive peerId from key field"
      return Opt.none(PublicKey)

    if derivedPeerId != m.fromPeer.get():
      warn "peerId derived from msg.key is not the same as msg.fromPeer",
        derivedPeerId = derivedPeerId, fromPeer = m.fromPeer
      return Opt.none(PublicKey)
    Opt.some(pubkey)
  else:
    Opt.none(PublicKey)

proc verify*(m: Message): bool =
  var verified = false
  if m.signature.isSome:
    var msg = m
    msg.signature = Opt.none(seq[byte])
    msg.key = Opt.none(seq[byte])

    var remote: Signature
    let key = m.extractPublicKey().valueOr:
      warn "could not extract public key", msg = m
      return false

    if remote.init(m.signature.get()):
      trace "verifying signature", remoteSignature = remote
      verified = remote.verify(PubSubPrefix & msg.encode(false), key)

  if verified:
    libp2p_pubsub_sig_verify_success.inc()
  else:
    libp2p_pubsub_sig_verify_failure.inc()
  verified

proc init*(
    T: type Message,
    peer: Opt[PeerInfo],
    data: sink seq[byte],
    topic: string,
    seqno: Opt[uint64],
    sign: bool = true,
): Message {.gcsafe, raises: [].} =
  if sign and peer.isNone():
    doAssert(false, "Cannot sign message without peer info")

  var msg = Message(data: Opt.some(move(data)), topic: topic)

  # order matters, we want to include seqno in the signature
  seqno.withValue(seqn):
    msg.seqno = Opt.some(@(seqn.toBytesBE()))

  peer.withValue(peer):
    msg.fromPeer = Opt.some(peer.peerId)
    if sign:
      msg.signature = sign(msg, peer.privateKey).toOpt()
      msg.key =
        peer.privateKey.getPublicKey().expect("Invalid private key!").getBytes().toOpt()

  msg

proc init*(
    T: type Message,
    peerId: PeerId,
    data: sink seq[byte],
    topic: string,
    seqno: Opt[uint64],
): Message {.gcsafe, raises: [].} =
  var msg =
    Message(fromPeer: Opt.some(peerId), data: Opt.some(move(data)), topic: topic)

  seqno.withValue(seqn):
    msg.seqno = Opt.some(@(seqn.toBytesBE()))
  msg

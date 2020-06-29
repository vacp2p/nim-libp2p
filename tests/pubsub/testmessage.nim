import unittest
import nimcrypto/sha2,
       stew/[base64, byteutils]
import ../../libp2p/[peer,
                     crypto/crypto,
                     protocols/pubsub/rpc/message,
                     protocols/pubsub/rpc/messages]

suite "Message":
  test "default message id":
    let msg = Message(fromPeer: PeerID.init(PrivateKey.random(ECDSA).get()).get().data,
                       seqno: ("12345").toBytes())

    check msg.msgId == byteutils.toHex(msg.seqno) & PeerID.init(msg.fromPeer).get().pretty()

  test "sha256 message id":
    let msg = Message(fromPeer: PeerID.init(PrivateKey.random(ECDSA).get()).get().data,
                       seqno: ("12345").toBytes(),
                       data: ("12345").toBytes())

    proc msgIdProvider(m: Message): string =
      Base64Url.encode(
        sha256.
        digest(m.data).
        data.
        toOpenArray(0, sha256.sizeDigest() - 1))

    check msg.msgId == Base64Url.encode(
        sha256.
        digest(msg.data).
        data.
        toOpenArray(0, sha256.sizeDigest() - 1))


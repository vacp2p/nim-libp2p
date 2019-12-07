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
import nimcrypto/sysrand
import messages, protobuf,
       ../../../peer,
       ../../../peerinfo,
       ../../../crypto/crypto,
       ../../../protobuf/minprotobuf

logScope:
  topic = "PubSubMessage"

const PubSubPrefix = "libp2p-pubsub:"

proc msgId*(m: Message): string =
  m.seqno.toHex() & PeerID.init(m.fromPeer).pretty

proc fromPeerId*(m: Message): PeerId =
  PeerID.init(m.fromPeer)

proc sign*(p: PeerInfo, msg: Message): Message {.gcsafe.} = 
  var buff = initProtoBuffer()
  encodeMessage(msg, buff)
  let prefix = cast[seq[byte]](PubSubPrefix)
  if buff.buffer.len > 0:
    result = msg
    result.signature = p.privateKey.
                       sign(prefix & buff.buffer).
                       getBytes()

proc verify*(p: PeerInfo, m: Message): bool =
  if m.signature.len > 0 and m.key.len > 0:
    var msg = m
    msg.signature = @[]
    msg.key = @[]

    var buff = initProtoBuffer()
    encodeMessage(msg, buff)

    var remote: Signature
    var key: PublicKey
    if remote.init(m.signature) and key.init(m.key):
      result = remote.verify(buff.buffer, key)

proc newMessage*(p: PeerInfo,
                 data: seq[byte],
                 name: string,
                 sign: bool = true): Message {.gcsafe.} = 
  var seqno: seq[byte] = newSeq[byte](20)
  if randomBytes(addr seqno[0], 20) > 0:
    var key: seq[byte] = p.publicKey.getBytes()

    result = Message(fromPeer: p.peerId.getBytes(),
                     data: data,
                     seqno: seqno,
                     topicIDs: @[name])
    if sign:
      result = p.sign(result)

    result.key = key

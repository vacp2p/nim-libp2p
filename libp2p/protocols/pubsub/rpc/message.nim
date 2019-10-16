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
       ../../../peerinfo,
       ../../../peer,
       ../../../crypto/crypto,
       ../../../protobuf/minprotobuf

logScope:
  topic = "PubSubMessage"

proc msgId*(m: Message): string =
  m.seqno.toHex() & PeerID.init(m.fromPeer).pretty

proc sign*(peerId: PeerID, msg: Message): Message = 
  var buff = initProtoBuffer()
  encodeMessage(msg, buff)
  # NOTE: leave as is, moving out would imply making this .threadsafe., etc...
  let prefix = cast[seq[byte]]("libp2p-pubsub:")
  if buff.buffer.len > 0:
    result = msg
    if peerId.privateKey.isSome:
      result.signature = peerId.
                         privateKey.
                         get().
                         sign(prefix & buff.buffer).
                         getBytes()

proc verify*(peerId: PeerID, m: Message): bool =
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

proc newMessage*(peerId: PeerID,
                 data: seq[byte],
                 name: string,
                 sign: bool = true): Message {.gcsafe.} = 
  var seqno: seq[byte] = newSeq[byte](20)
  if randomBytes(addr seqno[0], 20) > 0:
    var key: seq[byte] = @[]

    if peerId.publicKey.isSome:
      key = peerId.publicKey.get().getRawBytes()

    result = Message(fromPeer: peerId.getBytes(), 
                     data: data,
                     seqno: seqno,
                     topicIDs: @[name])
    if sign:
      result = sign(peerId, result)

    result.key = key

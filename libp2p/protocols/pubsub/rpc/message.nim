## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import nimcrypto/sysrand
import types,
       sign,
       ../../../peerinfo,
       ../../../peer,
       ../../../crypto/crypto

proc msgId*(m: Message): string =
  PeerID.init(m.fromPeer).pretty & m.seqno.toHex()

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

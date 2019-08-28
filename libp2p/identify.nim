## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import protobuf/minprotobuf, peerinfo, 
       switch, protocol as pr, connection

const IdentifyCodec = "/ipfs/id/1.0.0"
const IdentifyPushCodec = "/ipfs/id/push/1.0.0"

type
  # TODO: we're doing manual protobuf, this is only temporary
  ProtoField[T] = object
    index: int
    field: T

  IdentifyMsg = object
    protocolVersion: ProtoField[string]
    agentVersion: ProtoField[string]
    publicKey: ProtoField[seq[byte]]
    listenAddrs: ProtoField[seq[byte]]
    observedAddr: ProtoField[seq[byte]]
    protocols: ProtoField[seq[ProtoField[seq[string]]]]

  Identify = ref object of pr.Protocol

method dial*(p: Identify, peerInfo: PeerInfo): Future[Connection] {.async.} = discard
method handle*(p: Identify, peerInfo: PeerInfo, handler: pr.ProtoHandler) {.async.} = discard

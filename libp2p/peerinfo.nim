## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import peer, multiaddress

type 
  PeerInfo* = object of RootObj
    peerId*: Option[PeerID]
    addrs*: seq[MultiAddress]
    protocols*: seq[string]

proc id*(p: PeerInfo): string = 
  if p.peerId.isSome:
    result = p.peerId.get().pretty

proc `$`*(p: PeerInfo): string =
  if p.peerId.isSome:
    result.add("PeerID: ")
    result.add(p.id & "\n")

  if p.addrs.len > 0:
    result.add("Peer Addrs: ")
    for a in p.addrs:
      result.add($a & "\n")

  if p.protocols.len > 0:
    result.add("Protocols: ")
    for proto in p.protocols:
      result.add(proto & "\n")

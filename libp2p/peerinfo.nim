## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import peer, multiaddress, crypto/crypto

## A peer can be constructed in one of tree ways:
## 1) A local peer with a private key
## 2) A remote peer with a PeerID and it's public key stored
## in the ``id`` itself
## 3) A remote peer with a standalone public key, that isn't
## encoded in the ``id``
##

type
  KeyType* = enum
    HasPrivate,
    HasPublic

  PeerInfo* = ref object of RootObj
    peerId*: PeerID
    addrs*: seq[MultiAddress]
    protocols*: seq[string]
    case keyType*: KeyType:
    of HasPrivate:
      privateKey*: PrivateKey
    of HasPublic:
      key: Option[PublicKey]

proc init*(p: typedesc[PeerInfo],
           key: PrivateKey,
           addrs: seq[MultiAddress] = @[],
           protocols: seq[string] = @[]): PeerInfo {.inline.} =

  result = PeerInfo(keyType: HasPrivate,
                    peerId: PeerID.init(key),
                    privateKey: key,
                    addrs: addrs,
                    protocols: protocols)

proc init*(p: typedesc[PeerInfo],
           peerId: PeerID,
           addrs: seq[MultiAddress] = @[],
           protocols: seq[string] = @[]): PeerInfo {.inline.} =

  PeerInfo(keyType: HasPublic,
           peerId: peerId,
           addrs: addrs,
           protocols: protocols)

proc init*(p: typedesc[PeerInfo],
           peerId: string,
           addrs: seq[MultiAddress] = @[],
           protocols: seq[string] = @[]): PeerInfo {.inline.} =

  PeerInfo(keyType: HasPublic,
           peerId: PeerID.init(peerId),
           addrs: addrs,
           protocols: protocols)

proc init*(p: typedesc[PeerInfo],
           key: PublicKey,
           addrs: seq[MultiAddress] = @[],
           protocols: seq[string] = @[]): PeerInfo {.inline.} =

  PeerInfo(keyType: HasPublic,
           peerId: PeerID.init(key),
           key: some(key),
           addrs: addrs,
           protocols: protocols)

proc publicKey*(p: PeerInfo): Option[PublicKey] {.inline.} =
  if p.keyType == HasPublic:
    if p.peerId.hasPublicKey():
      var pubKey: PublicKey
      if p.peerId.extractPublicKey(pubKey):
        result = some(pubKey)
    elif p.key.isSome:
      result = p.key
  else:
    result = some(p.privateKey.getKey())

proc id*(p: PeerInfo): string {.inline.} =
  p.peerId.pretty

proc `$`*(p: PeerInfo): string =
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

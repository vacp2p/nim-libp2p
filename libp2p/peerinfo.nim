## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options, sequtils, hashes
import chronos, chronicles
import peerid, multiaddress, crypto/crypto

export peerid, multiaddress, crypto

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
    secureCodec*: string
    protocols*: seq[string]
    lifefut: Future[void]
    protoVersion*: string
    agentVersion*: string
    secure*: string
    case keyType*: KeyType:
    of HasPrivate:
      privateKey*: PrivateKey
    of HasPublic:
      key: Option[PublicKey]

proc id*(p: PeerInfo): string =
  if not(isNil(p)):
    return p.peerId.pretty()

proc `$`*(p: PeerInfo): string = p.id

proc shortLog*(p: PeerInfo): auto =
  (
    id: p.id(),
    secureCodec: p.secureCodec,
    addrs: mapIt(p.addrs, $it),
    protocols: mapIt(p.protocols, $it),
    protoVersion: p.protoVersion,
    agentVersion: p.agentVersion,
  )

template postInit(peerinfo: PeerInfo,
                  addrs: openarray[MultiAddress],
                  protocols: openarray[string]) =
  if len(addrs) > 0:
    peerinfo.addrs = @addrs
  if len(protocols) > 0:
    peerinfo.protocols = @protocols
  peerinfo.lifefut = newFuture[void]("libp2p.peerinfo.lifetime")

proc init*(p: typedesc[PeerInfo],
           key: PrivateKey,
           addrs: openarray[MultiAddress] = [],
           protocols: openarray[string] = []): PeerInfo {.inline.} =
  result = PeerInfo(keyType: HasPrivate, peerId: PeerID.init(key).tryGet(),
                    privateKey: key)
  result.postInit(addrs, protocols)

proc init*(p: typedesc[PeerInfo],
           peerId: PeerID,
           addrs: openarray[MultiAddress] = [],
           protocols: openarray[string] = []): PeerInfo {.inline.} =
  result = PeerInfo(keyType: HasPublic, peerId: peerId)
  result.postInit(addrs, protocols)

proc init*(p: typedesc[PeerInfo],
           peerId: string,
           addrs: openarray[MultiAddress] = [],
           protocols: openarray[string] = []): PeerInfo {.inline.} =
  result = PeerInfo(keyType: HasPublic, peerId: PeerID.init(peerId).tryGet())
  result.postInit(addrs, protocols)

proc init*(p: typedesc[PeerInfo],
           key: PublicKey,
           addrs: openarray[MultiAddress] = [],
           protocols: openarray[string] = []): PeerInfo {.inline.} =
  result = PeerInfo(keyType: HasPublic,
                    peerId: PeerID.init(key).tryGet(),
                    key: some(key))

  result.postInit(addrs, protocols)

proc close*(p: PeerInfo) {.inline.} =
  if not p.lifefut.finished:
    p.lifefut.complete()
  else:
    # TODO this should ideally not happen
    notice "Closing closed peer", peer = p.id

proc join*(p: PeerInfo): Future[void] {.inline.} =
  var retFuture = newFuture[void]()
  proc continuation(udata: pointer) {.gcsafe.} =
    if not(retFuture.finished()):
      retFuture.complete()
  proc cancellation(udata: pointer) {.gcsafe.} =
    p.lifefut.removeCallback(continuation)
  if p.lifefut.finished:
    retFuture.complete()
  else:
    p.lifefut.addCallback(continuation)
    retFuture.cancelCallback = cancellation
  return retFuture

proc isClosed*(p: PeerInfo): bool {.inline.} =
  result = p.lifefut.finished()

proc lifeFuture*(p: PeerInfo): Future[void] {.inline.} =
  result = p.lifefut

proc publicKey*(p: PeerInfo): Option[PublicKey] {.inline.} =
  if p.keyType == HasPublic:
    if p.peerId.hasPublicKey():
      var pubKey: PublicKey
      if p.peerId.extractPublicKey(pubKey):
        result = some(pubKey)
    elif p.key.isSome:
      result = p.key
  else:
    result = some(p.privateKey.getKey().tryGet())

func hash*(p: PeerInfo): Hash =
  cast[pointer](p).hash

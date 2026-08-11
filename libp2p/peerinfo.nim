# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[algorithm, sequtils]
import pkg/[chronos, chronicles, results]
import
  peerid,
  multiaddress,
  multicodec,
  crypto/crypto,
  routing_record,
  peeraddrpolicy,
  errors,
  utils/shortlog

export peerid, multiaddress, crypto, routing_record, peeraddrpolicy, errors, results

const p2pMultiCodec = multiCodec("p2p")

const DefaultNotifyDebounce* = 100.milliseconds

type
  PeerInfoError* = object of LPError

  AddressMapper* = proc(listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.
    gcsafe, async: (raises: [CancelledError])
  .} ## A proc that resolves listen addresses into dialable addresses.

  PeerInfoObserver* = proc(p: PeerInfo) {.gcsafe, raises: [].}
    ## A callback type for observing changes in a `PeerInfo`'s resolved addresses.
    ## `PeerInfo` object passed to the observer contains the updated state at the time of the callback.
    ##
    ## This observer is invoked in two scenarios:
    ## 1. Automatically after a call to `PeerInfo.update`, which may change the
    ##    resolved `addrs` list.
    ## 2. Manually when `PeerInfo.notifyObservers` is called explicitly.
    ##
    ## `notifyDebounce` coalesces a burst of both into a single trailing call.

  PeerInfo* = ref object ## PeerInfo represents our local peer info
    peerId*: PeerId
    listenAddrs*: seq[MultiAddress]
    ## contains addresses the node listens on, which may include wildcard and private addresses (not directly reachable).
    announcedAddrs*: seq[MultiAddress]
    ## explicit addresses to announce to peers, distinct from listenAddrs.
    ## When non-empty, these replace the output of the mapper chain, allowing a
    ## node to advertise (e.g.) a public NAT-mapped address while binding
    ## locally. The `AddressManager` applies them; a `PeerInfo` which runs no
    ## mapper applies them itself. The addressPolicy filter is still applied.
    addrs*: seq[MultiAddress]
    ## contains resolved addresses that other peers can use to connect, including public-facing NAT and port-forwarded addresses.
    addressMappers*: seq[AddressMapper]
    ## contains a list of procs that can be used to resolve the listen addresses into dialable addresses.
    addressPolicy*: PeerAddressPolicy
    ## applied after address mappers
    protocols*: seq[string]
    protoVersion*: string
    agentVersion*: string
    privateKey*: PrivateKey
    publicKey*: PublicKey
    signedPeerRecord*: SignedPeerRecord
    observers: seq[PeerInfoObserver]
    notifyDebounce*: Duration
    ## the shortest interval between two notifications. The first one is
    ## immediate; the ones raised during the interval are coalesced into a
    ## single notification at its end.
    notifyFut: Future[void]
    notifyPending: bool

func shortLog*(p: PeerInfo): auto =
  (
    peerId: $p.peerId,
    listenAddrs: p.listenAddrs.mapIt($it),
    addrs: p.addrs.mapIt($it),
    protocols: p.protocols.mapIt($it),
    protoVersion: p.protoVersion,
    agentVersion: p.agentVersion,
  )

chronicles.formatIt(PeerInfo):
  shortLog(it)

proc addObserver*(p: PeerInfo, observer: PeerInfoObserver) =
  if observer.isNil:
    return
  p.observers.add(observer)

proc removeObserver*(p: PeerInfo, observer: PeerInfoObserver) =
  p.observers.keepItIf(it != observer)

proc notifyNow(p: PeerInfo) =
  for observer in p.observers:
    observer(p)

proc quietPeriod(p: PeerInfo) {.async: (raises: []).} =
  try:
    await sleepAsync(p.notifyDebounce)
  except CancelledError:
    return
  if p.notifyPending:
    p.notifyPending = false
    p.notifyNow()

proc notifyObservers*(p: PeerInfo) =
  if p.notifyDebounce <= ZeroDuration:
    p.notifyNow()
    return

  if p.notifyFut.isNil() or p.notifyFut.finished():
    p.notifyNow()
    p.notifyFut = p.quietPeriod()
    return

  p.notifyPending = true

proc stopNotifications*(p: PeerInfo) {.async: (raises: []).} =
  p.notifyPending = false
  if p.notifyFut.isNil():
    return
  await p.notifyFut.cancelAndWait()
  p.notifyFut = nil

proc expandAddrs*(
    p: PeerInfo
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  var addrs = p.listenAddrs
  for mapper in p.addressMappers:
    addrs = await mapper(addrs)

  # the mappers still run: a port mapper has to map the bound ports even when
  # the operator picks what is announced
  if p.announcedAddrs.len > 0:
    addrs = p.announcedAddrs

  p.addressPolicy.filterAddrs(addrs)

proc update*(p: PeerInfo) {.async: (raises: [CancelledError]).} =
  var hasChanged: bool
  defer:
    if hasChanged:
      p.notifyObservers()

  let newAddrs = await p.expandAddrs()

  hasChanged = p.addrs.sorted() != newAddrs.sorted()
  p.addrs = newAddrs

  p.signedPeerRecord = SignedPeerRecord.init(
    p.privateKey, PeerRecord.init(p.peerId, p.addrs)
  ).valueOr:
    info "Can't update the signed peer record"
    return

proc addrs*(p: PeerInfo): seq[MultiAddress] =
  p.addrs

proc fullAddrs*(p: PeerInfo): MaResult[seq[MultiAddress]] =
  let peerIdPart = ?MultiAddress.init(p2pMultiCodec, p.peerId.data)
  var res = newSeqOfCap[MultiAddress](p.addrs.len)
  for address in p.addrs:
    res.add(?concat(address, peerIdPart))
  ok(res)

proc stripPeerId*(ma: MultiAddress): MultiAddress =
  ## Strip a terminal /p2p/<peer-id> suffix from a dial address.
  ## Keeps relay route components like /p2p/<relay>/p2p-circuit intact.
  let maLen = ma.len().valueOr:
    return ma

  if maLen < 2:
    return ma

  let lastPart = ma[^1].valueOr:
    return ma

  let protoCode = lastPart.protoCode().valueOr:
    return ma
  if protoCode != p2pMultiCodec:
    return ma

  let protoArg = lastPart.protoArgument().valueOr:
    return ma

  discard PeerId.init(protoArg).valueOr:
    return ma

  ma[0 .. ^2].valueOr:
    return ma

proc parseFullAddress*(ma: MultiAddress): MaResult[(PeerId, MultiAddress)] =
  let p2pPart = ?ma[^1]
  if ?p2pPart.protoCode != p2pMultiCodec:
    return err("missing p2p part from multiaddress")

  let peerId = ?PeerId.init(?p2pPart.protoArgument()).orErr("invalid peerid")

  ok((peerId, ?ma[0 .. ^2]))

proc parseFullAddress*(ma: string | seq[byte]): MaResult[(PeerId, MultiAddress)] =
  parseFullAddress(?MultiAddress.init(ma))

proc toFullAddress*(peerId: PeerId, ma: MultiAddress): MaResult[MultiAddress] =
  let peerIdPart = ?MultiAddress.init(p2pMultiCodec, peerId.data)
  concat(ma, peerIdPart)

proc new*(
    p: typedesc[PeerInfo],
    key: PrivateKey,
    listenAddrs: openArray[MultiAddress] = [],
    protocols: openArray[string] = [],
    protoVersion: string = "",
    agentVersion: string = "",
    addressMappers = newSeq[AddressMapper](),
    addressPolicy: PeerAddressPolicy = defaultAddressPolicy,
    announcedAddrs: openArray[MultiAddress] = [],
    notifyDebounce = DefaultNotifyDebounce,
): PeerInfo {.raises: [LPError].} =
  let pubkey = key.getPublicKey().valueOr:
    raise
      newException(PeerInfoError, "invalid private key creating PeerInfo: " & $error)
  let peerId = PeerId.init(pubkey).valueOr:
    raise newException(
      PeerInfoError, "invalid public key creating PeerInfo peer id: " & $error
    )

  PeerInfo(
    peerId: peerId,
    publicKey: pubkey,
    privateKey: key,
    protoVersion: protoVersion,
    agentVersion: agentVersion,
    listenAddrs: @listenAddrs,
    announcedAddrs: @announcedAddrs,
    protocols: @protocols,
    addressMappers: addressMappers,
    addressPolicy: addressPolicy,
    notifyDebounce: notifyDebounce,
  )

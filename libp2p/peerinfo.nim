# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}
{.push public.}

import std/sequtils
import pkg/[chronos, chronicles, results]
import peerid, multiaddress, multicodec, crypto/crypto, routing_record, errors, utility

export peerid, multiaddress, crypto, routing_record, errors, results

## Our local peer info

type
  PeerInfoError* = object of LPError

  AddressMapper* = proc(listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.
    gcsafe, async: (raises: [CancelledError])
  .} ## A proc that expected to resolve the listen addresses into dialable addresses

  PeerInfo* {.public.} = ref object
    peerId*: PeerId
    listenAddrs*: seq[MultiAddress]
    ## contains addresses the node listens on, which may include wildcard and private addresses (not directly reachable).
    addrs*: seq[MultiAddress]
    ## contains resolved addresses that other peers can use to connect, including public-facing NAT and port-forwarded addresses.
    addressMappers*: seq[AddressMapper]
    ## contains a list of procs that can be used to resolve the listen addresses into dialable addresses.
    protocols*: seq[string]
    protoVersion*: string
    agentVersion*: string
    privateKey*: PrivateKey
    publicKey*: PublicKey
    signedPeerRecord*: SignedPeerRecord

func shortLog*(p: PeerInfo): auto =
  (
    peerId: $p.peerId,
    listenAddrs: mapIt(p.listenAddrs, $it),
    addrs: mapIt(p.addrs, $it),
    protocols: mapIt(p.protocols, $it),
    protoVersion: p.protoVersion,
    agentVersion: p.agentVersion,
  )
chronicles.formatIt(PeerInfo):
  shortLog(it)

proc update*(p: PeerInfo) {.async: (raises: [CancelledError]).} =
  # p.addrs.len == 0 overrides addrs only if it is the first time update is being executed or if the field is empty.
  # p.addressMappers.len == 0 is for when all addressMappers have been removed,
  # and we wish to have addrs in its initial state, i.e., a copy of listenAddrs.
  if p.addrs.len == 0 or p.addressMappers.len == 0:
    p.addrs = p.listenAddrs
  for mapper in p.addressMappers:
    p.addrs = await mapper(p.addrs)

  p.signedPeerRecord = SignedPeerRecord.init(
    p.privateKey, PeerRecord.init(p.peerId, p.addrs)
  ).valueOr:
    info "Can't update the signed peer record"
    return

proc addrs*(p: PeerInfo): seq[MultiAddress] =
  p.addrs

proc fullAddrs*(p: PeerInfo): MaResult[seq[MultiAddress]] =
  let peerIdPart = ?MultiAddress.init(multiCodec("p2p"), p.peerId.data)
  var res: seq[MultiAddress]
  for address in p.addrs:
    res.add(?concat(address, peerIdPart))
  ok(res)

proc parseFullAddress*(ma: MultiAddress): MaResult[(PeerId, MultiAddress)] =
  let p2pPart = ?ma[^1]
  if ?p2pPart.protoCode != multiCodec("p2p"):
    return err("Missing p2p part from multiaddress!")

  let res =
    (?PeerId.init(?p2pPart.protoArgument()).orErr("invalid peerid"), ?ma[0 .. ^2])
  ok(res)

proc parseFullAddress*(ma: string | seq[byte]): MaResult[(PeerId, MultiAddress)] =
  parseFullAddress(?MultiAddress.init(ma))

proc new*(
    p: typedesc[PeerInfo],
    key: PrivateKey,
    listenAddrs: openArray[MultiAddress] = [],
    protocols: openArray[string] = [],
    protoVersion: string = "",
    agentVersion: string = "",
    addressMappers = newSeq[AddressMapper](),
): PeerInfo {.raises: [LPError].} =
  let pubkey =
    try:
      key.getPublicKey().tryGet()
    except CatchableError as e:
      raise
        newException(PeerInfoError, "invalid private key creating PeerInfo: " e.msg, e)

  let peerId = PeerId.init(key).tryGet()

  let peerInfo = PeerInfo(
    peerId: peerId,
    publicKey: pubkey,
    privateKey: key,
    protoVersion: protoVersion,
    agentVersion: agentVersion,
    listenAddrs: @listenAddrs,
    protocols: @protocols,
    addressMappers: addressMappers,
  )

  return peerInfo

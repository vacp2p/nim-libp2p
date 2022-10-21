# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}
{.push public.}

import std/[options, sequtils]
import pkg/[chronos, chronicles, stew/results]
import peerid, multiaddress, crypto/crypto, routing_record, errors, utility

export peerid, multiaddress, crypto, routing_record, errors, results

## Our local peer info

type
  PeerInfoError* = object of LPError

  AddressMapper* =
    proc(listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]]
      {.gcsafe, raises: [Defect].}

  PeerInfo* {.public.} = ref object
    peerId*: PeerId
    listenAddrs*: seq[MultiAddress]
    addrs: seq[MultiAddress]
    addressMappers*: seq[AddressMapper]
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
chronicles.formatIt(PeerInfo): shortLog(it)

proc update*(p: PeerInfo) {.async.} =
  p.addrs = p.listenAddrs
  for mapper in p.addressMappers:
    p.addrs = await mapper(p.addrs)

  let sprRes = SignedPeerRecord.init(
    p.privateKey,
    PeerRecord.init(p.peerId, p.addrs)
  )
  if sprRes.isOk:
    p.signedPeerRecord = sprRes.get()
  else:
    discard
    #info "Can't update the signed peer record"

proc addrs*(p: PeerInfo): seq[MultiAddress] =
  p.addrs

proc new*(
  p: typedesc[PeerInfo],
  key: PrivateKey,
  listenAddrs: openArray[MultiAddress] = [],
  protocols: openArray[string] = [],
  protoVersion: string = "",
  agentVersion: string = "",
  addressMappers = newSeq[AddressMapper](),
  ): PeerInfo
  {.raises: [Defect, LPError].} =

  let pubkey = try:
      key.getPublicKey().tryGet()
    except CatchableError:
      raise newException(PeerInfoError, "invalid private key")

  let peerId = PeerId.init(key).tryGet()

  let peerInfo = PeerInfo(
    peerId: peerId,
    publicKey: pubkey,
    privateKey: key,
    protoVersion: protoVersion,
    agentVersion: agentVersion,
    listenAddrs: @listenAddrs,
    protocols: @protocols,
    addressMappers: addressMappers
  )

  return peerInfo

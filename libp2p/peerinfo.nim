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
import peerid, multiaddress, multicodec, crypto/crypto, routing_record, errors, utility

export peerid, multiaddress, crypto, routing_record, errors, results

## Our local peer info

type
  PeerInfoError* = LPError

  PeerInfo* {.public.} = ref object
    peerId*: PeerId
    addrs*: seq[MultiAddress]
    protocols*: seq[string]
    protoVersion*: string
    agentVersion*: string
    privateKey*: PrivateKey
    publicKey*: PublicKey
    signedPeerRecord*: SignedPeerRecord

func shortLog*(p: PeerInfo): auto =
  (
    peerId: $p.peerId,
    addrs: mapIt(p.addrs, $it),
    protocols: mapIt(p.protocols, $it),
    protoVersion: p.protoVersion,
    agentVersion: p.agentVersion,
  )
chronicles.formatIt(PeerInfo): shortLog(it)

proc update*(p: PeerInfo) =
  let sprRes = SignedPeerRecord.init(
    p.privateKey,
    PeerRecord.init(p.peerId, p.addrs)
  )
  if sprRes.isOk:
    p.signedPeerRecord = sprRes.get()
  else:
    discard
    #info "Can't update the signed peer record"

proc fullAddrs*(p: PeerInfo): seq[MultiAddress] {.raises: [LPError].} =
  let peerIdPart = MultiAddress.init(multiCodec("p2p"), p.peerId.data).tryGet()
  for address in p.addrs:
    let fullAddr = address & peerIdPart
    result.add(fullAddr)

proc parseFullAddress*(ma: MultiAddress): (PeerId, MultiAddress) {.raises: [LPError].} =
  let p2pPart = ma[^1].tryGet()
  if p2pPart.protoCode.tryGet() != multiCodec("p2p"):
    raise newException(MaError, "Missing p2p part from multiaddress!")

  result[1] = ma[0 .. ^2].tryGet()
  result[0] = PeerId.init(p2pPart.protoArgument().tryGet()).tryGet()

proc parseFullAddress*(ma: string): (PeerId, MultiAddress) {.raises: [LPError].} =
  MultiAddress.init(ma).tryGet().parseFullAddress()

proc new*(
  p: typedesc[PeerInfo],
  key: PrivateKey,
  addrs: openArray[MultiAddress] = [],
  protocols: openArray[string] = [],
  protoVersion: string = "",
  agentVersion: string = ""): PeerInfo
  {.raises: [Defect, PeerInfoError].} =

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
    addrs: @addrs,
    protocols: @protocols,
  )

  peerInfo.update()

  return peerInfo

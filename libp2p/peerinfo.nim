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

proc fullAddrs*(p: PeerInfo): MaResult[seq[MultiAddress]] =
  let peerIdPart = ? MultiAddress.init(multiCodec("p2p"), p.peerId.data)
  var res: seq[MultiAddress]
  for address in p.addrs:
    res.add(? concat(address, peerIdPart))
  ok(res)

proc parseFullAddress*(ma: MultiAddress): MaResult[(PeerId, MultiAddress)] =
  let p2pPart = ? ma[^1]
  if ? p2pPart.protoCode != multiCodec("p2p"):
    return err("Missing p2p part from multiaddress!")

  let res = (
    ? PeerId.init(? p2pPart.protoArgument()).orErr("invalid peerid"),
    ? ma[0 .. ^2]
  )
  ok(res)

proc parseFullAddress*(ma: string | seq[byte]): MaResult[(PeerId, MultiAddress)] =
  parseFullAddress(? MultiAddress.init(ma))

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

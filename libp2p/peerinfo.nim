## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[options, sequtils, hashes]
import pkg/[chronos, chronicles, stew/results]
import peerid, multiaddress, crypto/crypto, errors

export peerid, multiaddress, crypto, errors, results

## Our local peer info

type
  PeerInfoError* = LPError

  PeerInfo* = ref object
    peerId*: PeerID
    addrs*: seq[MultiAddress]
    protocols*: seq[string]
    protoVersion*: string
    agentVersion*: string
    privateKey*: PrivateKey
    publicKey*: PublicKey

func shortLog*(p: PeerInfo): auto =
  (
    peerId: $p.peerId,
    addrs: mapIt(p.addrs, $it),
    protocols: mapIt(p.protocols, $it),
    protoVersion: p.protoVersion,
    agentVersion: p.agentVersion,
  )
chronicles.formatIt(PeerInfo): shortLog(it)

proc init*(
  p: typedesc[PeerInfo],
  key: PrivateKey,
  addrs: openarray[MultiAddress] = [],
  protocols: openarray[string] = [],
  protoVersion: string = "",
  agentVersion: string = ""): PeerInfo
  {.raises: [Defect, PeerInfoError].} =

  let pubkey = try:
      key.getKey().tryGet()
    except CatchableError:
      raise newException(PeerInfoError, "invalid private key")

  let peerInfo = PeerInfo(
    peerId: PeerID.init(key).tryGet(),
    publicKey: pubkey,
    privateKey: key,
    protoVersion: protoVersion,
    agentVersion: agentVersion,
    addrs: @addrs,
    protocols: @protocols)

  return peerInfo

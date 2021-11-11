## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[options, sequtils, hashes, times]
import pkg/[chronos, chronicles, stew/byteutils, stew/results]
import peerid, multiaddress, crypto/crypto, signed_envelope, routing_record, errors

export peerid, multiaddress, crypto, signed_envelope, errors, results

## Our local peer info

## Constants relating to signed peer records
const
  EnvelopePayloadType* = "/libp2p/routing-state-record".toBytes() # payload_type for routing records as spec'ed in RFC0003
  EnvelopeDomain* = "libp2p-routing-record" # envelope domain as per RFC0002

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
    signedPeerRecord*: Option[Envelope]

proc createSignedPeerRecord(peerId: PeerID, addrs: seq[MultiAddress], key: PrivateKey): Result[Envelope, CryptoError] =
  ## Creates a signed peer record for this peer:
  ## a peer routing record according to https://github.com/libp2p/specs/blob/master/RFC/0003-routing-records.md
  ## in a signed envelope according to https://github.com/libp2p/specs/blob/master/RFC/0002-signed-envelopes.md

  # First create a peer record from the peer info
  let peerRecord = PeerRecord.init(peerId,
                                   getTime().toUnix().uint64, # This currently follows the recommended implementation, using unix epoch as seq no.
                                   addrs)

  # Wrap peer record in envelope and sign
  let envelope = ? Envelope.init(key,
                                 EnvelopePayloadType,
                                 peerRecord.encode(),
                                 EnvelopeDomain)
  
  ok(envelope)

func shortLog*(p: PeerInfo): auto =
  (
    peerId: $p.peerId,
    addrs: mapIt(p.addrs, $it),
    protocols: mapIt(p.protocols, $it),
    protoVersion: p.protoVersion,
    agentVersion: p.agentVersion,
  )
chronicles.formatIt(PeerInfo): shortLog(it)

proc new*(
  p: typedesc[PeerInfo],
  key: PrivateKey,
  addrs: openarray[MultiAddress] = [],
  protocols: openarray[string] = [],
  protoVersion: string = "",
  agentVersion: string = ""): PeerInfo
  {.raises: [Defect, PeerInfoError].} =

  let pubkey = try:
      key.getPublicKey().tryGet()
    except CatchableError:
      raise newException(PeerInfoError, "invalid private key")
  
  let peerId = PeerID.init(key).tryGet()

  # TODO: should using signed peer records be configurable?
  let sprRes = createSignedPeerRecord(peerId, @addrs, key)
  let spr = if sprRes.isOk:
              some(sprRes.get())
            else:
              none(Envelope)

  let peerInfo = PeerInfo(
    peerId: peerId,
    publicKey: pubkey,
    privateKey: key,
    protoVersion: protoVersion,
    agentVersion: agentVersion,
    addrs: @addrs,
    protocols: @protocols,
    signedPeerRecord: spr)

  return peerInfo

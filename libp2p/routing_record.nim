## Nim-Libp2p
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements Routing Records.

{.push raises: [Defect].}

import std/[sequtils, times]
import pkg/stew/[results, byteutils]
import
  multiaddress,
  multicodec,
  peerid,
  protobuf/minprotobuf,
  signed_envelope

export peerid, multiaddress, signed_envelope

## Constants relating to signed peer records
const
  EnvelopeDomain = multiCodec("libp2p-peer-record") # envelope domain as per RFC0002
  EnvelopePayloadType= @[(byte) 0x03, (byte) 0x01] # payload_type for routing records as spec'ed in RFC0003

type
  AddressInfo* = object
    address*: MultiAddress

  PeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]

proc decode*(
  T: typedesc[PeerRecord],
  buffer: seq[byte]): Result[PeerRecord, ProtoError] =

  let pb = initProtoBuffer(buffer)
  var record = PeerRecord()

  ? pb.getRequiredField(1, record.peerId)
  ? pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  let pb3 = ? pb.getRepeatedField(3, addressInfos)

  if pb3:
    for address in addressInfos:
      var addressInfo = AddressInfo()
      let subProto = initProtoBuffer(address)
      if ? subProto.getField(1, addressInfo.address) == false:
        return err(ProtoError.RequiredFieldMissing)

      record.addresses &= addressInfo

  ok(record)

proc encode*(record: PeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    var addrPb = initProtoBuffer()
    addrPb.write(1, address.address)
    pb.write(3, addrPb)

  pb.finish()
  pb.buffer

proc init*(T: typedesc[PeerRecord],
  peerId: PeerId,
  seqNo: uint64,
  addresses: seq[MultiAddress]): T =

  PeerRecord(
    peerId: peerId,
    seqNo: seqNo,
    addresses: addresses.mapIt(AddressInfo(address: it))
  )


## Functions related to signed peer records

proc init*(T: typedesc[Envelope],
           privateKey: PrivateKey,
           peerRecord: PeerRecord): Result[Envelope, CryptoError] =
  
  ## Init a signed envelope wrapping a peer record

  let envelope = ? Envelope.init(privateKey,
                                 EnvelopePayloadType,
                                 peerRecord.encode(),
                                 $EnvelopeDomain)
  
  ok(envelope)

proc init*(T: typedesc[Envelope],
           peerId: PeerId,
           addresses: seq[MultiAddress],
           privateKey: PrivateKey): Result[Envelope, CryptoError] =
  ## Creates a signed peer record for this peer:
  ## a peer routing record according to https://github.com/libp2p/specs/blob/500a7906dd7dd8f64e0af38de010ef7551fd61b6/RFC/0003-routing-records.md
  ## in a signed envelope according to https://github.com/libp2p/specs/blob/500a7906dd7dd8f64e0af38de010ef7551fd61b6/RFC/0002-signed-envelopes.md
  
  # First create a peer record from the peer info
  let peerRecord = PeerRecord.init(peerId,
                                   getTime().toUnix().uint64, # This currently follows the recommended implementation, using unix epoch as seq no.
                                   addresses)

  let envelope = ? Envelope.init(privateKey,
                                 peerRecord)
  
  ok(envelope)

proc getSignedPeerRecord*(pb: ProtoBuffer, field: int,
               value: var Envelope): ProtoResult[bool] {.
     inline.} =
  getField(pb, field, value, $EnvelopeDomain)

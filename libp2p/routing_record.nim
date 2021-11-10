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

import std/sequtils
import pkg/stew/[results, byteutils]
import
  multiaddress,
  peerid,
  protobuf/minprotobuf

export peerid, multiaddress

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

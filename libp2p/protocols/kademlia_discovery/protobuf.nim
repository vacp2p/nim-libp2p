# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[tables, sets, heapqueue, times]
import chronos, chronicles, results, nimcrypto/sha2
import ../../[peerid, switch, multihash, cid, multicodec, routing_record]
import ../../protobuf/minprotobuf
import ./types

proc decode*(
    T: typedesc[ServiceInfo], buffer: seq[byte]
): Result[ServiceInfo, ProtoError] =
  var pb = initProtoBuffer(buffer)
  var servInf = ServiceInfo()

  ?pb.getRequiredField(1, servInf.id)
  discard ?pb.getField(2, servInf.data)

  ok(servInf)

proc decode*(
    T: typedesc[ExtPeerRecord], buffer: seq[byte]
): Result[ExtPeerRecord, ProtoError] =
  var pb = initProtoBuffer(buffer)
  var record = ExtPeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(3, addressInfos):
    for addressBuf in addressInfos:
      let addressInfo = AddressInfo.decode(addressBuf).valueOr:
        continue

      record.addresses &= addressInfo

    if record.addresses.len == 0:
      return err(ProtoError.RequiredFieldMissing)

  var serviceInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(4, serviceInfos):
    for serviceBuf in serviceInfos:
      record.services &= ?ServiceInfo.decode(serviceBuf)

  ok(record)

proc encode*(servInfo: ServiceInfo): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, servInfo.id)

  if servInfo.data.len > 0:
    pb.write(2, servInfo.data)

  pb.finish()
  return pb.buffer

proc encode*(record: ExtPeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    pb.write(3, address.encode())

  for service in record.services:
    pb.write(4, service.encode())

  pb.finish()
  return pb.buffer

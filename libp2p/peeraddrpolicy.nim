# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import results
import multiaddress, routing_record, wire

type PeerAddressPolicy* = ref object
  accept*: proc(ma: MultiAddress): bool {.gcsafe, raises: [].}

proc accepts*(policy: PeerAddressPolicy, ma: MultiAddress): bool =
  policy.isNil or policy.accept.isNil or policy.accept(ma)

proc filterAddrs*(
    policy: PeerAddressPolicy, addrs: openArray[MultiAddress]
): seq[MultiAddress] =
  if policy.isNil or policy.accept.isNil:
    return @addrs
  addrs.filterIt(policy.accept(it))

proc preservesAddrs*(policy: PeerAddressPolicy, addrs: openArray[MultiAddress]): bool =
  policy.filterAddrs(addrs).len == addrs.len

proc filterPeerRecord*(policy: PeerAddressPolicy, record: PeerRecord): Opt[PeerRecord] =
  if policy.isNil or policy.accept.isNil:
    return Opt.some(record)

  var filtered = record
  filtered.addresses.keepItIf(policy.accepts(it.address))
  if filtered.addresses.len == 0:
    return Opt.none(PeerRecord)
  Opt.some(filtered)

proc allowsSignedPeerRecord*(
    policy: PeerAddressPolicy, signedPeerRecord: seq[byte]
): bool =
  if policy.isNil or policy.accept.isNil:
    return true

  let spr = SignedPeerRecord.decode(signedPeerRecord).valueOr:
    return false

  policy.preservesAddrs(spr.data.addresses.mapIt(it.address))

proc publicRoutableAddressPolicy*(): PeerAddressPolicy =
  PeerAddressPolicy(
    accept: proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
      not isFilterablePrivateMA(ma)
  )

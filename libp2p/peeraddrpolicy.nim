# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import results
import multiaddress, routing_record, wire

type PeerAddressPolicy* = object
  accept*: proc(ma: MultiAddress): bool {.gcsafe, raises: [].}

proc defaultAddressPolicy*(): PeerAddressPolicy =
  ## The default policy that accepts all addresses. Used so that consumers can
  ## always rely on a policy with a non-nil `accept` proc.
  PeerAddressPolicy(
    accept: proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
      true
  )

proc accepts*(policy: PeerAddressPolicy, ma: MultiAddress): bool =
  doAssert not policy.accept.isNil, "invalid peerAddr policy"
  policy.accept(ma)

proc filterAddrs*(
    policy: PeerAddressPolicy, addrs: openArray[MultiAddress]
): seq[MultiAddress] =
  doAssert not policy.accept.isNil, "invalid peerAddr policy"
  addrs.filterIt(policy.accept(it))

proc preservesAddrs*(policy: PeerAddressPolicy, addrs: openArray[MultiAddress]): bool =
  policy.filterAddrs(addrs).len == addrs.len

proc filterPeerRecord*(policy: PeerAddressPolicy, record: PeerRecord): Opt[PeerRecord] =
  doAssert not policy.accept.isNil, "invalid peerAddr policy"

  var filtered = record
  filtered.addresses.keepItIf(policy.accepts(it.address))
  if filtered.addresses.len == 0:
    return Opt.none(PeerRecord)
  Opt.some(filtered)

proc publicRoutableAddressPolicy*(): PeerAddressPolicy =
  PeerAddressPolicy(
    accept: proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
      not isFilterablePrivateMA(ma)
  )

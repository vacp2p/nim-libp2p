# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import multiaddress, routing_record, wire

type PeerAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].}

const defaultAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  true

proc accepts*(policy: PeerAddressPolicy, ma: MultiAddress): bool =
  policy(ma)

proc filterAddrs*(
    policy: PeerAddressPolicy, addrs: openArray[MultiAddress]
): seq[MultiAddress] =
  addrs.filterIt(policy(it))

const publicRoutableAddressPolicy* = proc(
    ma: MultiAddress
): bool {.gcsafe, raises: [].} =
  not isFilterablePrivateMA(ma)

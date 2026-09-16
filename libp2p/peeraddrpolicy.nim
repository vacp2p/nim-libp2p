# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import multiaddress, routing_record, wire

type PeerAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].}

const defaultAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  true

proc accepts*(policy: PeerAddressPolicy, ma: MultiAddress): bool =
  policy.isNil() or policy(ma)

proc filterAddrs*(
    policy: PeerAddressPolicy, addrs: openArray[MultiAddress]
): seq[MultiAddress] =
  addrs.filterIt(policy.accepts(it))

proc dialableAddrs*(
    policy: PeerAddressPolicy, addrs: openArray[MultiAddress], allowUndialable = false
): seq[MultiAddress] =
  ## A preset chooses `policy`, and `allowUndialable` keeps `0.0.0.0` for a local test.
  addrs.filterIt((allowUndialable or isDialableMA(it)) and policy(it))

const publicRoutableAddressPolicy* = proc(
    ma: MultiAddress
): bool {.gcsafe, raises: [].} =
  ## Returns if this address should be filtered out because it is private
  ## or not globally routable. Circuit relay addresses are never filtered even
  ## if the relay itself has a private IP, since the relay address may still
  ## provide connectivity.

  isCircuitRelayMA(ma) or isPublicMA(ma)

const noPrivateAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  ## Returns if this address should be filtered out because they are
  ## neither public, circuit-relay or loopback

  isCircuitRelayMA(ma) or isPublicMA(ma) or isLoopbackMA(ma)

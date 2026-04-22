# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import multiaddress, routing_record, wire

type PeerAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].}

const defaultAddressPolicy* = proc(ma: MultiAddress): bool {.gcsafe, raises: [].} =
  false

proc accepts*(policy: PeerAddressPolicy, ma: MultiAddress): bool =
  not policy(ma)

proc filterAddrs*(
    policy: PeerAddressPolicy, addrs: openArray[MultiAddress]
): seq[MultiAddress] =
  addrs.filterIt(not policy(it))

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
  ## either public, circuit-relay or loopback

  isCircuitRelayMA(ma) or isPublicMA(ma) or isLoopbackMA(ma)

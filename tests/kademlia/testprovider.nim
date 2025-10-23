# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/heapqueue
from std/times import now, utc
import chronos, chronicles, nimcrypto
import unittest2
import ../tools/[unittest]
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../utils/async_tests
import ./utils.nim

suite "KadDHT - ProviderManager":
  teardown:
    checkTrackers()

  asyncTest "Add provider":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad1.bootstrap(@[switch2.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)
    kad2.dataTable.insert(key, value, $times.now().utc)

    # ensure providermanager is empty
    check kad1.providerManager.records.len() == 0

    await kad2.addProvider(key.toCid())
    await sleepAsync(10.milliseconds)

    debug "asdf", key = key, records = kad1.providerManager.records

    # kad1 has kad2 in its providermanager after adding provider
    check:
      kad1.providerManager.records.len() == 1
      kad1.providerManager.records[0].provider.id == sha256.digest(kad2.rtable.selfId)

  # asyncTest "Provider expired":
  # asyncTest "Provider refreshed (not expired)":
  # asyncTest "Start/stop providing":

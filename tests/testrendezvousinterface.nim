{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import sequtils, strutils
import chronos
import ../libp2p/[protocols/rendezvous,
                  switch,
                  builders,]
import ../libp2p/discovery/[rendezvousinterface, discoverymngr]
import ./helpers

proc createSwitch(rdv: RendezVous = RendezVous.new()): Switch =
  SwitchBuilder.new()
    .withRng(newRng())
    .withAddresses(@[ MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet() ])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withRendezVous(rdv)
    .build()

type
  MockRendezVous = ref object of RendezVous
    numAdvertise: int

  MockErrorRendezVous = ref object of MockRendezVous

method advertise*(self: MockRendezVous, namespace: string, ttl: Duration) {.async.} =
  # Every time an advertisement is made, increment the counter
  self.numAdvertise += 1
  # Forward the call to the actual implementation
  await procCall RendezVous(self).advertise(namespace, ttl)

method advertise*(self: MockErrorRendezVous, namespace: string, ttl: Duration) {.async.} =
  await procCall MockRendezVous(self).advertise(namespace, ttl)
  raise newException(CatchableError, "MockErrorRendezVous.advertise")

suite "RendezVous Interface":
  teardown:
    checkTrackers()

  proc baseTimeToAdvertiseTest(rdv: MockRendezVous) {.async.} =
    let
      tta = 100.milliseconds
      ttl = 2.hours
      client = createSwitch(rdv)
      dm = DiscoveryManager()

    await client.start()
    dm.add(RendezVousInterface.new(rdv = rdv, tta = tta, ttl = ttl))
    dm.advertise(RdvNamespace("ns"))

    # Run for 500ms, which with a 100ms advertise interval, should lead to 5 advertisements
    await sleepAsync(500.milliseconds)
    await client.stop()

    check rdv.numAdvertise == 5

  asyncTest "Check timeToAdvertise interval":
    await baseTimeToAdvertiseTest(MockRendezVous.new(newRng()))

  asyncTest "Check timeToAdvertise interval when there is an error":
    await baseTimeToAdvertiseTest(MockErrorRendezVous.new(newRng()))

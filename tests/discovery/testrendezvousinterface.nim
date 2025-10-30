# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/byteutils
import
  ../../libp2p/[
    protocols/rendezvous,
    protocols/rendezvous/protobuf,
    discovery/rendezvousinterface,
    discovery/discoverymngr,
    switch,
    builders,
    utils/semaphore,
    utils/offsettedseq,
  ]
import ../tools/[unittest]
import ./utils

type
  MockRendezVous = ref object of RendezVous
    numAdvertiseNs1: int
    numAdvertiseNs2: int

  MockErrorRendezVous = ref object of MockRendezVous

method advertise*(
    self: MockRendezVous, namespace: string, ttl: Opt[Duration] = Opt.none(Duration)
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  if namespace == "ns1":
    self.numAdvertiseNs1 += 1
  elif namespace == "ns2":
    self.numAdvertiseNs2 += 1
  # Forward the call to the actual implementation
  await procCall RendezVous(self).advertise(namespace, ttl)

method advertise*(
    self: MockErrorRendezVous,
    namespace: string,
    ttl: Opt[Duration] = Opt.none(Duration),
) {.async: (raises: [CancelledError, AdvertiseError]).} =
  await procCall MockRendezVous(self).advertise(namespace, ttl)
  raise newException(AdvertiseError, "MockErrorRendezVous.advertise")

proc new*(
    T: typedesc[MockRendezVous],
    rng: ref HmacDrbgContext = newRng(),
    minDuration = rendezvous.MinimumDuration,
    maxDuration = rendezvous.MaximumDuration,
): T =
  var minD = minDuration
  var maxD = maxDuration
  if minD < rendezvous.MinimumAcceptedDuration:
    minD = rendezvous.MinimumAcceptedDuration
  if maxD > rendezvous.MaximumDuration:
    maxD = rendezvous.MaximumDuration
  if minD >= maxD:
    minD = rendezvous.MinimumAcceptedDuration
    maxD = rendezvous.MaximumDuration

  let
    minTTL = minD.seconds.uint64
    maxTTL = maxD.seconds.uint64

  result = MockRendezVous(
    rng: rng,
    salt: string.fromBytes(generateBytes(rng[], 8)),
    registered: initOffsettedSeq[RegisteredData](),
    expiredDT: Moment.now() - 1.days,
    sema: newAsyncSemaphore(SemaphoreDefaultSize),
    minDuration: minDuration,
    maxDuration: maxDuration,
    minTTL: minTTL,
    maxTTL: maxTTL,
    peerRecordValidator: checkPeerRecord,
    numAdvertiseNs1: 0,
    numAdvertiseNs2: 0,
  )

  # Capture result in a local variable for the closure
  let rdv = result

  # Set up the protocol handler
  proc handleStream(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      let
        buf = await conn.readLp(4096)
        msg = Message.decode(buf).tryGet()
      case msg.msgType
      of MessageType.Register:
        await rdv.register(
          conn, msg.register.tryGet(), rdv.switch.peerInfo.signedPeerRecord.data
        )
      of MessageType.RegisterResponse:
        discard # trace "Got an unexpected Register Response"
      of MessageType.Unregister:
        rdv.unregister(conn, msg.unregister.tryGet())
      of MessageType.Discover:
        await rdv.discover(conn, msg.discover.tryGet())
      of MessageType.DiscoverResponse:
        discard # trace "Got an unexpected Discover Response"
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      discard # trace "exception in rendezvous handler"
    finally:
      await conn.close()

  result.handler = handleStream
  result.codec = rendezvous.RendezVousCodec

proc new*(T: typedesc[MockErrorRendezVous]): T =
  let base = MockRendezVous.new()
  result = MockErrorRendezVous(
    rng: base.rng,
    salt: base.salt,
    registered: base.registered,
    expiredDT: base.expiredDT,
    sema: base.sema,
    minDuration: base.minDuration,
    maxDuration: base.maxDuration,
    minTTL: base.minTTL,
    maxTTL: base.maxTTL,
    peerRecordValidator: base.peerRecordValidator,
    numAdvertiseNs1: 0,
    numAdvertiseNs2: 0,
  )
  # Copy the inherited LPProtocol fields
  result.handler = base.handler
  result.codec = base.codec

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
    dm.advertise(RdvNamespace("ns1"))
    dm.advertise(RdvNamespace("ns2"))

    checkUntilTimeout:
      rdv.numAdvertiseNs1 >= 5
    checkUntilTimeout:
      rdv.numAdvertiseNs2 >= 5
    await client.stop()

  asyncTest "Check timeToAdvertise interval":
    await baseTimeToAdvertiseTest(MockRendezVous.new())

  asyncTest "Check timeToAdvertise interval when there is an error":
    await baseTimeToAdvertiseTest(MockErrorRendezVous.new())

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, metrics
import ../../libp2p/[peerid, protocols/protocol, stream/connection]
import ../tools/[unittest, crypto]

proc handler(
    stream: Stream, proto: string
): Future[void] {.async: (raises: [CancelledError]).} =
  discard

template handleKeyError(body: untyped): float64 =
  try:
    body
  except exceptions.KeyError:
    0.0

template rejectionCounter(dir: string, scope: string): float64 =
  handleKeyError:
    libp2p_protocol_stream_cap_rejections_total.value([codecs[0], dir, scope])

template openGaugeIn(proto: LPProtocol): float64 =
  handleKeyError:
    libp2p_protocol_streams_open.value([proto.codecs[0], "in"])

template openGaugeOut(proto: LPProtocol): float64 =
  handleKeyError:
    libp2p_protocol_streams_open.value([proto.codecs[0], "out"])

template clearGauges(codecs: seq[string]) =
  libp2p_protocol_streams_open.set(0, labelValues = [codecs[0], "in"])
  libp2p_protocol_streams_open.set(0, labelValues = [codecs[0], "out"])

suite "LPProtocol stream budget":
  const codecs = @["/test/1.0.0"]
  let
    peerId1 = PeerId.random(rng()).get()
    peerId2 = PeerId.random(rng()).get()
    peerId3 = PeerId.random(rng()).get()

  setup: # clear previous values
    clearGauges(codecs)

  test "canAcceptIncoming returns true with no limits":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check:
      p.canAcceptIncoming(peerId1)
      p.canAcceptIncoming(peerId2)

    check:
      rejectionCounter("in", "total") == 0.0
      rejectionCounter("in", "per_peer") == 0.0
      rejectionCounter("out", "total") == 0.0
      rejectionCounter("out", "per_peer") == 0.0

  test "canOpenOutgoing returns true with no limits":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check:
      p.canOpenOutgoing(peerId1)
      p.canOpenOutgoing(peerId2)

    check:
      rejectionCounter("in", "total") == 0.0
      rejectionCounter("in", "per_peer") == 0.0
      rejectionCounter("out", "total") == 0.0
      rejectionCounter("out", "per_peer") == 0.0

  test "reserveIncoming and releaseIncoming with per-peer limit":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsPerPeer = 2,
      maxIncomingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId1)
      p.openGaugeIn() == 1
      p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1)
      p.openGaugeIn() == 2
      p.canAcceptIncoming(peerId2) # other peer not affected

    check:
      not p.reserveIncoming(peerId1) # make rejection
      rejectionCounter("in", "per_peer") == 1
      not p.reserveIncoming(peerId1) # make rejection, again
      rejectionCounter("in", "per_peer") == 2

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    check:
      p.openGaugeIn() == 0
      p.openGaugeOut() == 0

  test "reserveIncoming and releaseIncoming with total limit":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = 2,
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId1)
      p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId2)
      not p.canAcceptIncoming(peerId3)

    check:
      not p.reserveIncoming(peerId3) # make rejection
      rejectionCounter("in", "total") == 1
      not p.reserveIncoming(peerId3) # make rejection, again
      rejectionCounter("in", "total") == 2

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId2)

    check:
      p.openGaugeIn() == 0
      p.openGaugeOut() == 0

  test "reserveOutgoing and releaseOutgoing with per-peer limit":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsPerPeer = 2,
      maxOutgoingStreamsTotal = Opt.none(int),
    )

    check p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      p.openGaugeOut() == 1
      p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      p.openGaugeOut() == 2
      not p.canOpenOutgoing(peerId1)
      not p.reserveOutgoing(peerId1) # make rejection
      p.openGaugeOut() == 2
      p.canOpenOutgoing(peerId2)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    check:
      p.openGaugeIn() == 0
      p.openGaugeOut() == 0

  test "reserveOutgoing and releaseOutgoing with total limit":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = 2,
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check:
      p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId2)
      p.openGaugeOut() == 2
      not p.canOpenOutgoing(peerId3)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId3)

    p.releaseOutgoing(peerId2)

    check:
      p.openGaugeIn() == 0
      p.openGaugeOut() == 0

  test "combined incoming and outgoing limits (per-peer and total)":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = 4,
      maxIncomingStreamsPerPeer = 2,
      maxOutgoingStreamsTotal = 4,
      maxOutgoingStreamsPerPeer = 2,
    )

    # Fill incoming per-peer for peerId1
    check:
      p.reserveIncoming(peerId1)
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1) # per-peer limit hit
      p.canAcceptIncoming(peerId2) # other peer ok

    # Fill incoming total
    check:
      p.reserveIncoming(peerId2)
      p.reserveIncoming(peerId3)
      p.openGaugeIn() == 4
      not p.canAcceptIncoming(peerId2) # total limit reached
      not p.canAcceptIncoming(peerId3) # total limit reached

    # Check outgoing concurrently
    check p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      p.reserveOutgoing(peerId1)
      not p.canOpenOutgoing(peerId1) # per-peer limit hit

    check:
      p.reserveOutgoing(peerId2)
      p.reserveOutgoing(peerId3)
      p.openGaugeOut() == 4
      not p.canOpenOutgoing(peerId2) # total outgoing limit reached

    # Release incoming and verify
    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)
      # peerId1 per-peer count now 1 < 2, and total 3 < 4

    # Release outgoing and verify
    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1) # peerId1 per-peer count now 1 < 2, and total 3 < 4

    check:
      p.openGaugeIn() == 3
      p.openGaugeOut() == 3

  test "release underflow protection (release without reserve)":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = 2,
      maxIncomingStreamsPerPeer = 2,
      maxOutgoingStreamsTotal = 2,
      maxOutgoingStreamsPerPeer = 2,
    )

    # Releasing without reserving should not cause negative counts
    p.releaseIncoming(peerId1)
    check:
      p.openGaugeIn() == 0
      p.canAcceptIncoming(peerId1)

    # Reserve up to limit, then release extra should keep within limits
    check:
      p.reserveIncoming(peerId1)
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1)

    p.releaseIncoming(peerId1)
    p.releaseIncoming(peerId1)
    check p.openGaugeIn() == 0

    # extra release for incoming
    p.releaseIncoming(peerId1)
    check:
      p.canAcceptIncoming(peerId1)
      p.openGaugeIn() == 0

    # extra release for outgoing
    p.releaseOutgoing(peerId1)
    check:
      p.canOpenOutgoing(peerId1)
      p.openGaugeOut() == 0

  test "budget with new() using int arguments directly (not Opt)":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = 2,
      maxIncomingStreamsPerPeer = 1,
      maxOutgoingStreamsTotal = 3,
      maxOutgoingStreamsPerPeer = 1,
    )

    check p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1) # per-peer limit 1
      p.openGaugeIn() == 1

    check:
      p.reserveIncoming(peerId2)
      not p.canAcceptIncoming(peerId3) # total limit 2 reached
      p.openGaugeIn() == 2

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    # Outgoing
    check p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      not p.canOpenOutgoing(peerId1) # per-peer limit 1
      p.openGaugeOut() == 1

    check:
      p.reserveOutgoing(peerId2)
      p.reserveOutgoing(peerId3)
      p.openGaugeOut() == 3
      not p.canOpenOutgoing(peerId1) # total limit 3 reached

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    check:
      p.openGaugeIn() == 1
      p.openGaugeOut() == 2

  test "different peers share total budget correctly":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = 2,
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = 2,
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    # Incoming
    check:
      p.reserveIncoming(peerId1)
      p.canAcceptIncoming(peerId1)
      p.reserveIncoming(peerId2)
      not p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId3)

    # Outgoing
    check:
      p.reserveOutgoing(peerId1)
      p.canOpenOutgoing(peerId2)
      p.reserveOutgoing(peerId2)
      not p.canOpenOutgoing(peerId3)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId3)

    check:
      p.openGaugeIn() == 1
      p.openGaugeOut() == 1

  test "reserveIncoming and releaseIncoming with per-peer limit using Opt.some":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.some(1),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1)
      p.canAcceptIncoming(peerId2) # other peer still allowed

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    check:
      p.openGaugeIn() == 0
      p.openGaugeOut() == 0

  test "reserveOutgoing and releaseOutgoing with per-peer limit using Opt.some":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.some(1),
    )

    check p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      not p.canOpenOutgoing(peerId1)
      p.canOpenOutgoing(peerId2)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    check:
      p.openGaugeIn() == 0
      p.openGaugeOut() == 0

  test "different protocols have different gauge":
    let p1 = LPProtocol.new(@["/proto-one/1.0.0"], handler)
    let p2 = LPProtocol.new(@["/proto-two/1.0.0"], handler)

    check:
      p1.reserveOutgoing(peerId1)
      p1.reserveOutgoing(peerId1)
      p1.reserveOutgoing(peerId1)
      p1.openGaugeOut() == 3
      p2.openGaugeOut() == 0 # protocol two gauge is unchanged

    clearGauges(p1.codecs)

    check:
      p2.reserveOutgoing(peerId1)
      p2.reserveOutgoing(peerId1)
      p2.reserveOutgoing(peerId1)
      p2.openGaugeOut() == 3
      p1.openGaugeOut() == 0 # protocol one gauge is unchanged

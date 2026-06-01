# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../libp2p/[peerid, protocols/protocol, stream/connection]
import ../tools/[unittest, crypto]

proc handler(
    stream: Stream, proto: string
): Future[void] {.async: (raises: [CancelledError]).} =
  discard

template assertNoLimits(p: LPProtocol) =
  # when there are no limits reserve and release will always succeed

  # this for is here to drive over any limits (default of explicit)
  for i in 0 .. 1000:
    check:
      p.reserveIncoming(peerId1)
      p.reserveOutgoing(peerId1)

  check: # incoming
    p.canAcceptIncoming(peerId1)
    p.canAcceptIncoming(peerId2)
    p.reserveIncoming(peerId1)
    p.reserveIncoming(peerId1)
    p.reserveIncoming(peerId2)
    p.canAcceptIncoming(peerId1)
    p.canAcceptIncoming(peerId2)

  p.releaseIncoming(peerId1)
  p.releaseIncoming(peerId2)

  check: # outgoing
    p.canOpenOutgoing(peerId1)
    p.canOpenOutgoing(peerId2)
    p.reserveOutgoing(peerId1)
    p.reserveOutgoing(peerId1)
    p.reserveOutgoing(peerId2)
    p.canOpenOutgoing(peerId1)
    p.canOpenOutgoing(peerId2)

  p.releaseOutgoing(peerId1)
  p.releaseOutgoing(peerId2)

suite "LPProtocol stream budget":
  const codecs = @["/test/1.0.0"]
  let
    peerId1 = PeerId.random(rng()).get()
    peerId2 = PeerId.random(rng()).get()
    peerId3 = PeerId.random(rng()).get()

  test "LPProtocol with no limits (default values)":
    let p = LPProtocol.new(codecs, handler)
    assertNoLimits(p)

  test "LPProtocol with no limits (explicit values)":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = Opt.none(int),
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = Opt.none(int),
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )
    assertNoLimits(p)

  test "LPProtocol with no limits (created with new keword)":
    let p = new LPProtocol
    p.codecs = codecs
    assertNoLimits(p)

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
      p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1)
      p.canAcceptIncoming(peerId2) # other peer not affected

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

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

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId2)

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
      p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      not p.canOpenOutgoing(peerId1)
      p.canOpenOutgoing(peerId2)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

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
      not p.canOpenOutgoing(peerId3)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId3)

    p.releaseOutgoing(peerId2)

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
      not p.canOpenOutgoing(peerId2) # total outgoing limit reached

    # Release incoming and verify
    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)
      # peerId1 per-peer count now 1 < 2, and total 3 < 4

    # Release outgoing and verify
    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1) # peerId1 per-peer count now 1 < 2, and total 3 < 4

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
    check p.canAcceptIncoming(peerId1)

    # Reserve up to limit, then release extra should keep within limits
    check:
      p.reserveIncoming(peerId1)
      p.reserveIncoming(peerId1)
      not p.canAcceptIncoming(peerId1)

    p.releaseIncoming(peerId1)
    p.releaseIncoming(peerId1)
    # extra release
    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    # Same for outgoing
    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

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

    check:
      p.reserveIncoming(peerId2)
      not p.canAcceptIncoming(peerId3) # total limit 2 reached

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    # Outgoing
    check p.canOpenOutgoing(peerId1)

    check:
      p.reserveOutgoing(peerId1)
      not p.canOpenOutgoing(peerId1) # per-peer limit 1

    check:
      p.reserveOutgoing(peerId2)
      p.reserveOutgoing(peerId3)
      not p.canOpenOutgoing(peerId1) # total limit 3 reached

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

  test "different peers share total budget correctly":
    let p = LPProtocol.new(
      codecs,
      handler,
      maxIncomingStreamsTotal = 2,
      maxIncomingStreamsPerPeer = Opt.none(int),
      maxOutgoingStreamsTotal = 2,
      maxOutgoingStreamsPerPeer = Opt.none(int),
    )

    check:
      p.reserveIncoming(peerId1)
      p.canAcceptIncoming(peerId1)

    check:
      p.reserveIncoming(peerId2)
      not p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId2)

    # Outgoing
    check:
      p.reserveOutgoing(peerId1)
      p.reserveOutgoing(peerId2)
      not p.canOpenOutgoing(peerId3)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId3)

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

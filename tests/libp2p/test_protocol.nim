# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../libp2p/[peerid, protocols/protocol, stream/connection, utility]
import ../tools/[unittest, crypto]

proc handler(
    stream: Stream, proto: string
): Future[void] {.async: (raises: [CancelledError]).} =
  discard

suite "LPProtocol stream budget":
  const codecs = @["/test/1.0.0"]
  let
    peerId1 = PeerId.random(rng()).get()
    peerId2 = PeerId.random(rng()).get()
    peerId3 = PeerId.random(rng()).get()

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

    p.reserveIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    p.reserveIncoming(peerId1)
    check:
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

    p.reserveIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    p.reserveIncoming(peerId2)
    check not p.canAcceptIncoming(peerId3)

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

    p.reserveOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    p.reserveOutgoing(peerId1)
    check:
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

    p.reserveOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

    p.reserveOutgoing(peerId2)
    check not p.canOpenOutgoing(peerId3)

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
    p.reserveIncoming(peerId1)
    p.reserveIncoming(peerId1)
    check:
      not p.canAcceptIncoming(peerId1) # per-peer limit hit
      p.canAcceptIncoming(peerId2) # other peer ok

    # Fill incoming total
    p.reserveIncoming(peerId2)
    p.reserveIncoming(peerId3)
    check:
      not p.canAcceptIncoming(peerId2) # total limit reached
      not p.canAcceptIncoming(peerId3) # total limit reached

    # Check outgoing concurrently
    check p.canOpenOutgoing(peerId1)

    p.reserveOutgoing(peerId1)
    p.reserveOutgoing(peerId1)
    check not p.canOpenOutgoing(peerId1) # per-peer limit hit

    p.reserveOutgoing(peerId2)
    p.reserveOutgoing(peerId3)
    check not p.canOpenOutgoing(peerId2) # total outgoing limit reached

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
    p.reserveIncoming(peerId1)
    p.reserveIncoming(peerId1)
    check not p.canAcceptIncoming(peerId1)

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

    p.reserveIncoming(peerId1)
    check not p.canAcceptIncoming(peerId1) # per-peer limit 1

    p.reserveIncoming(peerId2)
    check not p.canAcceptIncoming(peerId3) # total limit 2 reached

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    # Outgoing
    check p.canOpenOutgoing(peerId1)

    p.reserveOutgoing(peerId1)
    check not p.canOpenOutgoing(peerId1) # per-peer limit 1

    p.reserveOutgoing(peerId2)
    p.reserveOutgoing(peerId3)
    check not p.canOpenOutgoing(peerId1) # total limit 3 reached

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

    p.reserveIncoming(peerId1)
    check p.canAcceptIncoming(peerId1)

    p.reserveIncoming(peerId2)
    check not p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId1)
    check p.canAcceptIncoming(peerId3)

    p.releaseIncoming(peerId2)

    # Outgoing
    p.reserveOutgoing(peerId1)
    p.reserveOutgoing(peerId2)
    check not p.canOpenOutgoing(peerId3)

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

    p.reserveIncoming(peerId1)
    check:
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

    p.reserveOutgoing(peerId1)
    check:
      not p.canOpenOutgoing(peerId1)
      p.canOpenOutgoing(peerId2)

    p.releaseOutgoing(peerId1)
    check p.canOpenOutgoing(peerId1)

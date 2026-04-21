# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/[extended_peer_record]
import ../../../libp2p/protocols/service_discovery/types
import ../../tools/[unittest]
import ./utils

suite "seq[Advertisement] encode":
  test "empty seq encodes to empty result":
    let ads: seq[Advertisement] = @[]
    check ads.encode(10).len == 0

  test "fReturn 0 encodes nothing":
    let ads = @[makeAdvertisement("svc")]
    check ads.encode(0).len == 0

  test "single advertisement encodes and round-trips":
    let ad = makeAdvertisement("svc")
    let encoded = @[ad].encode(10)
    check encoded.len == 1
    let decoded = SignedExtendedPeerRecord.decode(encoded[0])
    check:
      decoded.isOk()
      decoded.get() == ad

  test "all advertisements encoded when count is within fReturn":
    let ads = @[makeAdvertisement("a"), makeAdvertisement("b"), makeAdvertisement("c")]
    let encoded = ads.encode(10)
    check encoded.len == 3

  test "fReturn cap limits output count":
    let ads =
      @[
        makeAdvertisement("a"),
        makeAdvertisement("b"),
        makeAdvertisement("c"),
        makeAdvertisement("d"),
      ]
    check ads.encode(2).len == 2

  test "encoded advertisements decode back correctly":
    let origAds = @[makeAdvertisement("x"), makeAdvertisement("y")]
    let encoded = origAds.encode(10)
    check encoded.len == 2
    for i, bytes in encoded:
      let decoded = SignedExtendedPeerRecord.decode(bytes)
      check:
        decoded.isOk()
        decoded.get() == origAds[i]

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/protocols/mix/tag_manager
import ../../tools/unittest

proc makeTag(seed: byte): Tag =
  ## Helper to create a tag with a specific seed pattern
  for i in 0 ..< result.len:
    result[i] = byte((int(seed) * 32 + i) mod 256)

suite "Tag Manager":
  var tm: TagManager

  setup:
    # autoStart=false to avoid async loop in synchronous tests
    tm = TagManager.new(autoStart = false)

  teardown:
    tm.clearTags()

  test "add, check, and remove tags":
    let tag1 = makeTag(1)
    let tag2 = makeTag(2)

    # Initially empty
    check tm.len == 0
    check not tm.isTagSeen(tag1)
    check not tm.isTagSeen(tag2)

    # Add tags
    tm.addTag(tag1)
    tm.addTag(tag2)
    check tm.len == 2
    check tm.isTagSeen(tag1)
    check tm.isTagSeen(tag2)

    # Remove one tag
    tm.removeTag(tag1)
    check tm.len == 1
    check not tm.isTagSeen(tag1)
    check tm.isTagSeen(tag2)

    # Clear all
    tm.clearTags()
    check tm.len == 0

  test "duplicate tag is no-op":
    let tag = makeTag(1)

    tm.addTag(tag)
    check tm.len == 1

    # Adding same tag again should not change count
    tm.addTag(tag)
    check tm.len == 1

  test "tag expiration and purge":
    let shortTTL = chronos.milliseconds(30)
    let tmShort = TagManager.new(tagTTL = shortTTL, autoStart = false)

    let baseTime = Moment.now()

    # Add 3 tags at baseTime
    for i in 0 ..< 3:
      tmShort.addTag(makeTag(byte(i)), baseTime)
    check tmShort.len == 3

    # Add 2 more tags later (before first ones expire)
    let laterTime = baseTime + chronos.milliseconds(20)
    for i in 3 ..< 5:
      tmShort.addTag(makeTag(byte(i)), laterTime)
    check tmShort.len == 5

    # Purge when first 3 are expired but last 2 are not
    let purgeTime = baseTime + chronos.milliseconds(40)
    let purged = tmShort.purgeExpiredTags(purgeTime)

    check purged == 3
    check tmShort.len == 2
    check not tmShort.isTagSeen(makeTag(0))
    check not tmShort.isTagSeen(makeTag(1))
    check not tmShort.isTagSeen(makeTag(2))
    check tmShort.isTagSeen(makeTag(3))
    check tmShort.isTagSeen(makeTag(4))

  test "purge with no expired tags":
    tm.addTag(makeTag(1))

    # Purge immediately (nothing expired with 1-hour default TTL)
    let purged = tm.purgeExpiredTags()

    check purged == 0
    check tm.len == 1

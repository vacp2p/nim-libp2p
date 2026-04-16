# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/net
import ../../../libp2p/utils/iptree
import ../../tools/unittest

func ip4(a, b, c, d: uint8): IpAddress =
  IpAddress(family: IpAddressFamily.IPv4, address_v4: [a, b, c, d])

func ip6(): IpAddress =
  IpAddress(
    family: IpAddressFamily.IPv6,
    address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
  )

# IP Similarity Score Semantics:
# - Score range: 0.0 to 1.0
# - HIGH score (close to 1.0) = HIGH SIMILARITY = many IPs share prefixes = potential Sybil attack
# - LOW score (close to 0.0) = LOW SIMILARITY = IPs well-distributed = normal behaviour
#
# The score is used to rate-limit advertisements from the same subnet.
# A high similarity score triggers increased waiting times for registration.

suite "IpTree":
  test "new IpTree has root counter set to 0":
    let tree = IpTree.new()
    check tree.root.counter == 0
    check tree.root.left.isNil
    check tree.root.right.isNil

  test "insertIp creates correct tree structure":
    let tree = IpTree.new()

    # 64.0.0.1 = 01000000 ... → first bit 0 → goes LEFT
    let ip1 = ip4(64, 0, 0, 1)
    tree.insertIp(ip1)
    check tree.root.counter == 1
    check not tree.root.left.isNil
    check tree.root.right.isNil

    # 192.168.1.1 = 11000000 ... → first bit 1 → goes RIGHT
    let ip2 = ip4(192, 168, 1, 1)
    tree.insertIp(ip2)
    check tree.root.counter == 2
    check tree.root.left.counter == 1
    check tree.root.right.counter == 1

    # 128.0.0.1 = 10000000 ... → RIGHT then LEFT
    let ip3 = ip4(128, 0, 0, 1)
    tree.insertIp(ip3)
    check tree.root.counter == 3
    check tree.root.right.counter == 2
    check tree.root.right.left.counter == 1

    # Inserting the same IP again increments counters again
    tree.insertIp(ip1)
    check tree.root.counter == 4
    check tree.root.left.counter == 2

  test "removeIp decrements counters correctly":
    let tree = IpTree.new()
    let ip1 = ip4(64, 0, 0, 1)
    let ip2 = ip4(192, 168, 1, 1)
    let ip3 = ip4(128, 0, 0, 1)

    tree.insertIp(ip1)
    tree.insertIp(ip1)
    tree.insertIp(ip2)
    tree.insertIp(ip3)
    check tree.root.counter == 4

    tree.removeIp(ip1)
    check tree.root.counter == 3
    check tree.root.left.counter == 1

    tree.removeIp(ip3)
    check tree.root.counter == 2
    check tree.root.right.left.counter == 0

    tree.removeIp(ip1)
    tree.removeIp(ip2)
    check tree.root.counter == 0

  test "removeIp should not affect tree if IP was never inserted":
    let tree = IpTree.new()
    tree.insertIp(ip4(192, 168, 1, 1))
    tree.insertIp(ip4(192, 168, 1, 2))
    check tree.root.counter == 2

    tree.removeIp(ip4(10, 0, 0, 1))

    check tree.root.counter == 2

  test "removeIp on empty tree should not allow negative counters":
    let tree = IpTree.new()
    tree.removeIp(ip4(192, 168, 1, 1))
    check tree.root.counter == 0

  test "removeIp should not allow counters to go below zero":
    let tree = IpTree.new()
    let ip = ip4(192, 168, 1, 1)

    tree.insertIp(ip)
    check tree.root.counter == 1

    tree.removeIp(ip)
    check tree.root.counter == 0

    tree.removeIp(ip)
    check tree.root.counter == 0

  test "insertIp asserts on IPv6":
    let tree = IpTree.new()
    expect AssertionDefect:
      tree.insertIp(ip6())

  test "removeIp asserts on IPv6":
    let tree = IpTree.new()
    expect AssertionDefect:
      tree.removeIp(ip6())

  test "ipScore asserts on IPv6":
    let tree = IpTree.new()
    expect AssertionDefect:
      discard tree.ipScore(ip6())

  test "ipScore returns 0.0 for empty tree":
    let tree = IpTree.new()
    check tree.ipScore(ip4(192, 168, 1, 1)) == 0.0

  test "ipScore returns high score for exact same IP":
    let tree = IpTree.new()
    let ip = ip4(192, 168, 1, 1)
    tree.insertIp(ip)
    check tree.ipScore(ip) > 0.9

  test "ipScore detects /24 subnet similarity":
    let tree = IpTree.new()
    tree.insertIp(ip4(192, 168, 1, 10))
    check tree.ipScore(ip4(192, 168, 1, 20)) > 0.7

  test "ipScore detects /16 subnet similarity":
    let tree = IpTree.new()
    tree.insertIp(ip4(192, 168, 1, 10))
    let score = tree.ipScore(ip4(192, 168, 2, 20))
    check score > 0.4 and score < 0.8

  test "ipScore detects /8 subnet similarity":
    let tree = IpTree.new()
    tree.insertIp(ip4(192, 168, 1, 10))
    let score = tree.ipScore(ip4(192, 255, 255, 255))
    check score > 0.1 and score < 0.5

  test "ipScore returns low score for completely different IPs":
    let tree = IpTree.new()
    # 192 = 11000000, 10 = 00001010 — first bits differ
    tree.insertIp(ip4(192, 168, 1, 1))
    check tree.ipScore(ip4(10, 0, 0, 1)) < 0.2

  test "ipScore demonstrates graduated similarity across prefix lengths":
    let tree = IpTree.new()
    let base = ip4(192, 168, 1, 100)
    tree.insertIp(base)

    check tree.ipScore(base) > 0.9
    check tree.ipScore(ip4(192, 168, 1, 200)) > 0.7

    let score16 = tree.ipScore(ip4(192, 168, 255, 255))
    check score16 > 0.4 and score16 <= 0.7

    let score8 = tree.ipScore(ip4(192, 255, 255, 255))
    check score8 > 0.1 and score8 <= 0.4

    check tree.ipScore(ip4(10, 0, 0, 1)) < 0.1

  test "insert and remove maintains scoring consistency":
    let tree = IpTree.new()
    let ip = ip4(192, 168, 1, 1)

    tree.insertIp(ip)
    check tree.ipScore(ip) > 0.9

    tree.removeIp(ip)
    check tree.ipScore(ip) == 0.0

  test "similar IPs with single bit difference":
    # 192.168.1.0 and 192.168.1.1 differ only in the last bit
    let tree = IpTree.new()
    tree.insertIp(ip4(192, 168, 1, 0))
    check tree.ipScore(ip4(192, 168, 1, 1)) > 0.9

  test "diverse IP distribution yields low individual scores":
    let tree = IpTree.new()
    tree.insertIp(ip4(10, 0, 0, 1))
    tree.insertIp(ip4(172, 16, 0, 1))
    tree.insertIp(ip4(192, 168, 0, 1))
    tree.insertIp(ip4(8, 8, 8, 8))
    tree.insertIp(ip4(1, 1, 1, 1))
    check tree.root.counter == 5

    # Same /8 as 10.0.0.1 → moderate score
    check tree.ipScore(ip4(10, 0, 0, 2)) > 0.7
    # Different from all existing IPs → low score
    check tree.ipScore(ip4(11, 0, 0, 1)) < 0.3

  test "threshold calculation at different tree depths":
    let tree = IpTree.new()
    for i in 1'u8 .. 8'u8:
      tree.insertIp(ip4(192, 168, 1, i))
    check tree.root.counter == 8

    # All 8 IPs share the same /24 prefix, so the shared-path counters are
    # well above the threshold at every depth → high score
    check tree.ipScore(ip4(192, 168, 1, 200)) > 0.7

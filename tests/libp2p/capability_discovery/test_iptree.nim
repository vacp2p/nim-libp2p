# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/net
import ../../../libp2p/protocols/capability_discovery/[types, iptree]
import ../../tools/unittest

suite "IpTree":
  test "new IpTree has empty root":
    let tree = IpTree.new()
    check tree.root.counter == 0
    check tree.root.left.isNil
    check tree.root.right.isNil

  test "insertIp increments root counter":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)

    # Root counter is incremented once per IP insertion (at the root level)
    check tree.root.counter == 1

  test "insertIp rejects IPv6 addresses":
    let tree = IpTree.new()
    let ip = parseIpAddress("::1")

    tree.insertIp(ip)
    check tree.root.counter == 0

  test "removeIp decrements root counter":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    check tree.root.counter == 1

    tree.removeIp(ip)
    check tree.root.counter == 0

  test "removeIp rejects IPv6 addresses":
    let tree = IpTree.new()
    let ip = parseIpAddress("::1")

    check tree.root.counter == 0
    tree.removeIp(ip)
    check tree.root.counter == 0

  test "ipScore returns 0.0 for empty tree":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.ipScore(ip) == 0.0

  test "ipScore returns high score for same IP after insert":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    let score = tree.ipScore(ip)
    # Score should be close to 1.0 for the exact same IP
    # The exact value depends on the threshold calculation
    check score > 0.9

  test "ipScore returns 0.0 for different IP class":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.1")
    let ip2 = parseIpAddress("10.0.0.1")

    tree.insertIp(ip1)
    # 192 = 11000000, 10 = 00001010 - first bits differ
    check tree.ipScore(ip2) == 0.0

  test "ipScore reflects prefix similarity - same /24":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.168.1.20")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # Same /24 means first 24 bits match, so we expect high score
    check score > 0.7

  test "ipScore reflects prefix similarity - different /24":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.168.2.20")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # Different /24, only first 16 bits match
    check score > 0.4 and score < 0.8

  test "ipScore reflects prefix similarity - different /16":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("10.0.0.1")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # First octet differs - very low score
    check score < 0.2

  test "insert multiple IPs and score correctly":
    let tree = IpTree.new()

    # Insert multiple IPs from same subnet
    for i in 1 .. 5:
      tree.insertIp(parseIpAddress("192.168.1." & $i))

    check tree.root.counter == 5

    let ip1 = parseIpAddress("192.168.1.10")
    check tree.ipScore(ip1) > 0.7

    let ip2 = parseIpAddress("10.0.0.1")
    check tree.ipScore(ip2) == 0.0

  test "insert multiple IPs from different subnets":
    let tree = IpTree.new()

    tree.insertIp(parseIpAddress("192.168.1.1"))
    tree.insertIp(parseIpAddress("192.168.2.1"))
    tree.insertIp(parseIpAddress("10.0.0.1"))

    check tree.root.counter == 3

    # IP in same /16 as first two
    let ip1 = parseIpAddress("192.168.3.1")
    let score1 = tree.ipScore(ip1)
    check score1 > 0.4

  test "removeIp after multiple inserts":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    tree.insertIp(ip)
    check tree.root.counter == 2

    tree.removeIp(ip)
    check tree.root.counter == 1

  test "insertIp creates correct tree structure":
    let tree = IpTree.new()
    let ip = parseIpAddress("128.0.0.1") # Binary: 10000000.00000000.00000000.00000001

    tree.insertIp(ip)

    # First bit is 1, so we should have a right child
    check not tree.root.right.isNil

  test "insertIp and removeIp maintain tree consistency":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    let score1 = tree.ipScore(ip)
    check score1 > 0.9

    tree.removeIp(ip)
    let score2 = tree.ipScore(ip)
    check score2 == 0.0

  test "insertIp with same IP multiple times affects scoring":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    let score1 = tree.ipScore(ip)

    tree.insertIp(ip)
    tree.insertIp(ip)
    let score2 = tree.ipScore(ip)

    # Score should be the same/higher as it's the same IP
    check score1 > 0.9
    check score2 > 0.9

  test "removeIp for similar IP decrements along shared path":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.1")
    let ip2 = parseIpAddress("192.168.1.2")

    tree.insertIp(ip1)
    check tree.root.counter == 1

    # ip2 shares most of the path with ip1
    tree.insertIp(ip2)
    check tree.root.counter == 2

    tree.removeIp(ip1)
    # Still have ip2, so root.counter should be 1
    check tree.root.counter == 1

  test "ipScore for IPs with varying prefix similarity":
    let tree = IpTree.new()
    let baseIp = parseIpAddress("192.168.1.100")
    tree.insertIp(baseIp)

    # Same IP - score should be high
    check tree.ipScore(baseIp) > 0.9

    # Same /24 (24 bits match) - high score
    let same24 = parseIpAddress("192.168.1.200")
    let score24 = tree.ipScore(same24)
    check score24 > 0.7

    # Same /16 (16 bits match) - medium score
    let same16 = parseIpAddress("192.168.255.255")
    let score16 = tree.ipScore(same16)
    check score16 > 0.4 and score16 <= 0.7

    # Same /8 (8 bits match) - lower score
    let same8 = parseIpAddress("192.255.255.255")
    let score8 = tree.ipScore(same8)
    check score8 > 0.1 and score8 <= 0.4

    # Different first octet - very low score
    let diffFirst = parseIpAddress("10.0.0.1")
    let scoreDiff = tree.ipScore(diffFirst)
    check scoreDiff < 0.1

  test "multiple inserts then multiple removes":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    tree.insertIp(ip)
    tree.insertIp(ip)
    check tree.root.counter == 3

    tree.removeIp(ip)
    tree.removeIp(ip)
    check tree.root.counter == 1

    tree.removeIp(ip)
    check tree.root.counter == 0

  test "ipScore increases with more IPs in same prefix":
    let tree = IpTree.new()

    # Insert IPs from same /24
    for i in 1 .. 10:
      tree.insertIp(parseIpAddress("192.168.1." & $i))

    let queryIp = parseIpAddress("192.168.1.100")
    let score = tree.ipScore(queryIp)

    # With more IPs in the same prefix, score should be high
    check score > 0.7

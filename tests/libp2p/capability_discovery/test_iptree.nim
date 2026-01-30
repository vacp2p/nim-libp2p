# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/net
import results
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

    check tree.insertIp(ip).isOk()

    # Root counter is incremented once per IP insertion (at the root level)
    check tree.root.counter == 1

  test "insertIp rejects IPv6 addresses":
    let tree = IpTree.new()
    let ip = parseIpAddress("::1")

    check tree.insertIp(ip).isErr()
    check tree.insertIp(ip).error() == Ipv4Required

  test "removeIp decrements root counter":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.insertIp(ip).isOk()
    check tree.root.counter == 1

    check tree.removeIp(ip).isOk()
    check tree.root.counter == 0

  test "removeIp rejects IPv6 addresses":
    let tree = IpTree.new()
    let ip = parseIpAddress("::1")

    check tree.removeIp(ip).isErr()
    check tree.removeIp(ip).error() == Ipv4Required

  test "ipScore returns 0.0 for empty tree":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.ipScore(ip).get() == 0.0

  test "ipScore returns high score for same IP after insert":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.insertIp(ip).isOk()
    let score = tree.ipScore(ip).get()
    # Score should be close to 1.0 for the exact same IP
    # The exact value depends on the threshold calculation
    check score > 0.9

  test "ipScore returns 0.0 for different IP class":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.1")
    let ip2 = parseIpAddress("10.0.0.1")

    check tree.insertIp(ip1).isOk()
    # 192 = 11000000, 10 = 00001010 - first bits differ
    check tree.ipScore(ip2).get() == 0.0

  test "ipScore reflects prefix similarity - same /24":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.168.1.20")

    check tree.insertIp(ip1).isOk()
    let score = tree.ipScore(ip2).get()

    # Same /24 means first 24 bits match, so we expect high score
    check score > 0.7

  test "ipScore reflects prefix similarity - different /24":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.168.2.20")

    check tree.insertIp(ip1).isOk()
    let score = tree.ipScore(ip2).get()

    # Different /24, only first 16 bits match
    check score > 0.4 and score < 0.8

  test "ipScore reflects prefix similarity - different /16":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("10.0.0.1")

    check tree.insertIp(ip1).isOk()
    let score = tree.ipScore(ip2).get()

    # First octet differs - very low score
    check score < 0.2

  test "insert multiple IPs and score correctly":
    let tree = IpTree.new()

    # Insert multiple IPs from same subnet
    for i in 1 .. 5:
      check tree.insertIp(parseIpAddress("192.168.1." & $i)).isOk()

    check tree.root.counter == 5

    let ip1 = parseIpAddress("192.168.1.10")
    check tree.ipScore(ip1).get() > 0.7

    let ip2 = parseIpAddress("10.0.0.1")
    check tree.ipScore(ip2).get() == 0.0

  test "insert multiple IPs from different subnets":
    let tree = IpTree.new()

    check tree.insertIp(parseIpAddress("192.168.1.1")).isOk()
    check tree.insertIp(parseIpAddress("192.168.2.1")).isOk()
    check tree.insertIp(parseIpAddress("10.0.0.1")).isOk()

    check tree.root.counter == 3

    # IP in same /16 as first two
    let ip1 = parseIpAddress("192.168.3.1")
    let score1 = tree.ipScore(ip1).get()
    check score1 > 0.4

  test "removeIp after multiple inserts":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.insertIp(ip).isOk()
    check tree.insertIp(ip).isOk()
    check tree.root.counter == 2

    check tree.removeIp(ip).isOk()
    check tree.root.counter == 1

  test "insertIp creates correct tree structure":
    let tree = IpTree.new()
    let ip = parseIpAddress("128.0.0.1") # Binary: 10000000.00000000.00000000.00000001

    check tree.insertIp(ip).isOk()

    # First bit is 1, so we should have a right child
    check not tree.root.right.isNil

  test "insertIp and removeIp maintain tree consistency":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.insertIp(ip).isOk()
    let score1 = tree.ipScore(ip).get()
    check score1 > 0.9

    check tree.removeIp(ip).isOk()
    let score2 = tree.ipScore(ip).get()
    check score2 == 0.0

  test "ipScore only supports IPv4":
    let tree = IpTree.new()
    check tree.insertIp(parseIpAddress("192.168.1.1")).isOk()

    let ipv6 = parseIpAddress("::1")

    check tree.ipScore(ipv6).isErr()
    check tree.ipScore(ipv6).error() == Ipv4Required

  test "insertIp with same IP multiple times affects scoring":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.insertIp(ip).isOk()
    let score1 = tree.ipScore(ip).get()

    check tree.insertIp(ip).isOk()
    check tree.insertIp(ip).isOk()
    let score2 = tree.ipScore(ip).get()

    # Score should be the same/higher as it's the same IP
    check score1 > 0.9
    check score2 > 0.9

  test "removeIp for similar IP decrements along shared path":
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.1")
    let ip2 = parseIpAddress("192.168.1.2")

    check tree.insertIp(ip1).isOk()
    check tree.root.counter == 1

    # ip2 shares most of the path with ip1
    check tree.insertIp(ip2).isOk()
    check tree.root.counter == 2

    check tree.removeIp(ip1).isOk()
    # Still have ip2, so root.counter should be 1
    check tree.root.counter == 1

  test "ipScore for IPs with varying prefix similarity":
    let tree = IpTree.new()
    let baseIp = parseIpAddress("192.168.1.100")
    check tree.insertIp(baseIp).isOk()

    # Same IP - score should be high
    check tree.ipScore(baseIp).get() > 0.9

    # Same /24 (24 bits match) - high score
    let same24 = parseIpAddress("192.168.1.200")
    let score24 = tree.ipScore(same24).get()
    check score24 > 0.7

    # Same /16 (16 bits match) - medium score
    let same16 = parseIpAddress("192.168.255.255")
    let score16 = tree.ipScore(same16).get()
    check score16 > 0.4 and score16 <= 0.7

    # Same /8 (8 bits match) - lower score
    let same8 = parseIpAddress("192.255.255.255")
    let score8 = tree.ipScore(same8).get()
    check score8 > 0.1 and score8 <= 0.4

    # Different first octet - very low score
    let diffFirst = parseIpAddress("10.0.0.1")
    let scoreDiff = tree.ipScore(diffFirst).get()
    check scoreDiff < 0.1

  test "multiple inserts then multiple removes":
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.insertIp(ip).isOk()
    check tree.insertIp(ip).isOk()
    check tree.insertIp(ip).isOk()
    check tree.root.counter == 3

    check tree.removeIp(ip).isOk()
    check tree.removeIp(ip).isOk()
    check tree.root.counter == 1

    check tree.removeIp(ip).isOk()
    check tree.root.counter == 0

  test "ipScore increases with more IPs in same prefix":
    let tree = IpTree.new()

    # Insert IPs from same /24
    for i in 1 .. 10:
      check tree.insertIp(parseIpAddress("192.168.1." & $i)).isOk()

    let queryIp = parseIpAddress("192.168.1.100")
    let score = tree.ipScore(queryIp).get()

    # With more IPs in the same prefix, score should be high
    check score > 0.7

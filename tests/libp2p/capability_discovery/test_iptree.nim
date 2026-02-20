# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/net
import ../../../libp2p/protocols/capability_discovery/[types, iptree]
import ../../tools/unittest

# IP Similarity Score Semantics:
# - Score range: 0.0 to 1.0
# - HIGH score (close to 1.0) = HIGH SIMILARITY = Many IPs share prefixes = Potential Sybil attack
# - LOW score (close to 0.0) = LOW SIMILARITY = IPs well-distributed = Normal behavior
#
# The score is used to detect and rate-limit advertisements from the same subnet.
# A high similarity score triggers increased waiting times for registration.

suite "IpTree":
  test "new IpTree has root counter set to 0":
    let tree = IpTree.new()
    check tree.root.counter == 0
    check tree.root.left.isNil
    check tree.root.right.isNil

  test "insertIp creates correct tree structure":
    let tree = IpTree.new()

    # IP 1: 64.0.0.1 = 01... (goes LEFT)
    let ip1 = parseIpAddress("64.0.0.1")
    tree.insertIp(ip1)
    check tree.root.counter == 1
    check not tree.root.left.isNil
    check tree.root.right.isNil

    # IP 2: 192.168.1.1 = 11... (goes RIGHT)
    let ip2 = parseIpAddress("192.168.1.1")
    tree.insertIp(ip2)
    check tree.root.counter == 2
    check tree.root.left.counter == 1
    check tree.root.right.counter == 1

    # IP 3: 128.0.0.1 = 10... (goes RIGHT then LEFT)
    let ip3 = parseIpAddress("128.0.0.1")
    tree.insertIp(ip3)
    check tree.root.counter == 3
    check tree.root.right.counter == 2
    check tree.root.right.left.counter == 1

    # Insert same IP multiple times
    tree.insertIp(ip1)
    check tree.root.counter == 4
    check tree.root.left.counter == 2

  test "removeIp decrements counters correctly":
    let tree = IpTree.new()

    let ip1 = parseIpAddress("64.0.0.1")
    let ip2 = parseIpAddress("192.168.1.1")
    let ip3 = parseIpAddress("128.0.0.1")

    # Setup tree
    tree.insertIp(ip1)
    tree.insertIp(ip1)
    tree.insertIp(ip2)
    tree.insertIp(ip3)
    check tree.root.counter == 4

    # Remove operations
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

    # Insert some IPs
    let ip1 = parseIpAddress("192.168.1.1")
    let ip2 = parseIpAddress("192.168.1.2")
    tree.insertIp(ip1)
    tree.insertIp(ip2)
    check tree.root.counter == 2

    # Try to remove IP that was never inserted
    let ip3 = parseIpAddress("10.0.0.1")
    tree.removeIp(ip3)

    check tree.root.counter == 2

  test "removeIp on empty tree should not allow negative counters":
    # Edge case: removing from empty tree should be prevented
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.removeIp(ip)
    check tree.root.counter == 0

  test "removeIp should not allow counters to go below zero":
    # Edge case: removing more times than inserted
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    check tree.root.counter == 1

    tree.removeIp(ip)
    check tree.root.counter == 0

    # Remove again when already at 0
    tree.removeIp(ip)
    check tree.root.counter == 0

  test "insertIp rejects IPv6 on empty tree":
    let tree = IpTree.new()
    let ip = parseIpAddress("::1")

    tree.insertIp(ip)
    check tree.root.counter == 0

  test "insertIp rejects IPv6 on populated tree":
    let tree = IpTree.new()

    # Populate tree with IPv4 addresses
    tree.insertIp(parseIpAddress("192.168.1.1"))
    tree.insertIp(parseIpAddress("10.0.0.1"))
    tree.insertIp(parseIpAddress("172.16.0.1"))
    check tree.root.counter == 3

    # Try to insert IPv6
    let ipv6 = parseIpAddress("::1")
    tree.insertIp(ipv6)

    # Counter should remain unchanged
    check tree.root.counter == 3

  test "removeIp rejects IPv6 on empty tree":
    let tree = IpTree.new()
    let ip = parseIpAddress("::1")

    tree.removeIp(ip)
    check tree.root.counter == 0

  test "removeIp rejects IPv6 on populated tree":
    let tree = IpTree.new()

    # Populate tree with IPv4 addresses
    tree.insertIp(parseIpAddress("192.168.1.1"))
    tree.insertIp(parseIpAddress("10.0.0.1"))
    tree.insertIp(parseIpAddress("172.16.0.1"))
    check tree.root.counter == 3

    # Try to remove IPv6
    let ipv6 = parseIpAddress("2001:db8::1")
    tree.removeIp(ipv6)

    # Counter should remain unchanged
    check tree.root.counter == 3

  test "ipScore returns 0.0 for empty tree":
    # No IPs in tree = no similarity = score 0.0
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    check tree.ipScore(ip) == 0.0

  test "ipScore returns high score for exact same IP":
    # Exact IP match = maximum similarity = potential Sybil attack
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    let score = tree.ipScore(ip)

    # All 32 bits match, all counters exceed threshold = score > 0.9
    check score > 0.9

  test "ipScore detects /24 subnet similarity":
    # IPs in same /24 subnet = high similarity = suspicious
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.168.1.20")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # First 24 bits match = high similarity score
    check score > 0.7

  test "ipScore detects /16 subnet similarity":
    # IPs in same /16 but different /24 = medium similarity
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.168.2.20")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # First 16 bits match, last 16 differ = medium score
    check score > 0.4 and score < 0.8

  test "ipScore detects /8 subnet similarity":
    # IPs in same /8 but different /16 = lower similarity
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.10")
    let ip2 = parseIpAddress("192.255.255.255")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # Only first 8 bits match = lower score
    check score > 0.1 and score < 0.5

  test "ipScore returns low score for completely different IPs":
    # IPs from different networks = low similarity = normal behavior
    let tree = IpTree.new()
    let ip1 = parseIpAddress("192.168.1.1")
    let ip2 = parseIpAddress("10.0.0.1")

    tree.insertIp(ip1)
    let score = tree.ipScore(ip2)

    # 192 = 11000000, 10 = 00001010 (first bits differ) = very low score
    check score < 0.2

  test "ipScore demonstrates graduated similarity across prefix lengths":
    # Comprehensive test showing how similarity degrades with prefix divergence
    let tree = IpTree.new()
    let baseIp = parseIpAddress("192.168.1.100")
    tree.insertIp(baseIp)

    # Same IP (32-bit match) = highest similarity
    check tree.ipScore(baseIp) > 0.9

    # Same /24 (24-bit match) = high similarity
    let same24 = parseIpAddress("192.168.1.200")
    check tree.ipScore(same24) > 0.7

    # Same /16 (16-bit match) = medium similarity
    let same16 = parseIpAddress("192.168.255.255")
    let score16 = tree.ipScore(same16)
    check score16 > 0.4 and score16 <= 0.7

    # Same /8 (8-bit match) = lower similarity
    let same8 = parseIpAddress("192.255.255.255")
    let score8 = tree.ipScore(same8)
    check score8 > 0.1 and score8 <= 0.4

    # Different first octet = very low similarity
    let diffFirst = parseIpAddress("10.0.0.1")
    check tree.ipScore(diffFirst) < 0.1

  test "insert and remove maintains scoring consistency":
    # Simulates ad expiration: score should return to 0
    let tree = IpTree.new()
    let ip = parseIpAddress("192.168.1.1")

    tree.insertIp(ip)
    let score1 = tree.ipScore(ip)
    check score1 > 0.9 # High similarity when IP is in tree

    tree.removeIp(ip)
    let score2 = tree.ipScore(ip)
    check score2 == 0.0 # No similarity when tree is empty

  test "similar IPs with single bit difference":
    # 192.168.1.0 and 192.168.1.1 differ only in last bit
    let tree = IpTree.new()

    let ip1 = parseIpAddress("192.168.1.0")
    let ip2 = parseIpAddress("192.168.1.1")

    tree.insertIp(ip1)

    # 31 out of 32 bits match = very high similarity
    let score = tree.ipScore(ip2)
    check score > 0.9

  test "diverse IP distribution yields low individual scores":
    # Well-distributed IPs = normal behavior = low similarity scores
    let tree = IpTree.new()

    # Insert IPs from completely different networks
    tree.insertIp(parseIpAddress("10.0.0.1")) # Class A private
    tree.insertIp(parseIpAddress("172.16.0.1")) # Class B private
    tree.insertIp(parseIpAddress("192.168.0.1")) # Class C private
    tree.insertIp(parseIpAddress("8.8.8.8")) # Google DNS
    tree.insertIp(parseIpAddress("1.1.1.1")) # Cloudflare DNS

    check tree.root.counter == 5

    # Query IP similar to one existing IP = moderate score
    check tree.ipScore(parseIpAddress("10.0.0.2")) > 0.7

    # Query IP different from all existing IPs = low score
    check tree.ipScore(parseIpAddress("11.0.0.1")) < 0.3

  test "threshold calculation at different tree depths":
    # Verify that threshold = root.counter / 2^depth is correctly applied
    let tree = IpTree.new()

    # Insert 8 IPs from same /24 to create high counters in shared path
    for i in 1 .. 8:
      tree.insertIp(parseIpAddress("192.168.1." & $i))

    check tree.root.counter == 8

    # At depth 0: threshold = 8/1 = 8 (root always meets threshold)
    # At depth 1: threshold = 8/2 = 4
    # At depth 2: threshold = 8/4 = 2
    # etc.
    # Counter at shared nodes (first 24 bits) exceeds thresholds

    let queryIp = parseIpAddress("192.168.1.200")
    let score = tree.ipScore(queryIp)

    # Should have high score due to shared prefix
    check score > 0.7

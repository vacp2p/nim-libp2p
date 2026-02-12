import unittest2
import std/[sequtils, math]
import ../../../libp2p/protocols/capability_discovery/[iptree, types]
import ../../../libp2p/multiaddress
import ../../../libp2p/protocols/connectivity/autonat/utils

const Eps = 1e-9

proc mkIp*(s: string): IpAddress =
  parseIpAddress(s)

proc mkTree*(ips: openArray[string]): IpTree =
  var t = IpTree.new()
  for ip in ips:
    t.insertIp(mkIp(ip))
  t

proc pathNodes*(t: IpTree, ip: IpAddress): seq[IpTreeNode] =
  ## Returns root + all nodes along the IPv4 path (32 steps), stopping early if the path breaks.
  result = @[t.root]
  if ip.family != IPv4:
    return
  let bits = ip.toBinary()
  var v = t.root
  for i in 0 ..< 32:
    if bits[i] == 0:
      v = v.left
    else:
      v = v.right
    if v.isNil:
      break
    result.add(v)

proc mkAd*(addrs: openArray[string]): Advertisement =
  Advertisement(addrs: (@addrs).mapIt(MultiAddress.init(it).tryGet()))

suite "Capability Discovery - IpTree":

  # Creating a new tree yields an empty root counter and no children.
  test "new tree has counter 0":
    let tree = IpTree.new()
    check tree.root.counter == 0
    check tree.root.left.isNil
    check tree.root.right.isNil

  # Inserting a single IPv4 increments the root and creates a non-empty path.
  test "insertIp increments counter":
    var tree = IpTree.new()
    tree.insertIp(mkIp("192.168.1.1"))
    check tree.root.counter == 1
    check not tree.root.left.isNil or not tree.root.right.isNil

  # IPv6 insertions are rejected and leave the tree unchanged.
  test "insertIp rejects Ipv6 addresses":
    var tree = IpTree.new()
    tree.insertIp(parseIpAddress("2001:db8::1"))
    check tree.root.counter == 0
    check tree.root.left.isNil
    check tree.root.right.isNil

  # Removing an inserted IPv4 decrements counters along the exact traversal path.
  test "removeIp decrements counters along path":
    var tree = IpTree.new()
    let ip = mkIp("10.0.0.1")
    tree.insertIp(ip)
    check tree.root.counter == 1

    tree.removeIp(ip)
    check tree.root.counter == 0

    let nodes = tree.pathNodes(ip)
    for n in nodes:
      check n.counter == 0

  # IPv6 removals are rejected and do not mutate the tree.
  test "removeIp rejects Ipv6 addresses":
    var tree = IpTree.new()
    tree.removeIp(parseIpAddress("2001:db8::1"))
    check tree.root.counter == 0
    check tree.root.left.isNil
    check tree.root.right.isNil

  # On an empty tree, ipScore returns 1.0 (no observed similarity).
  test "ipScore returns 1.0 for empty tree":
    let tree = IpTree.new()
    let score = tree.ipScore(mkIp("192.168.1.1"))
    check abs(score - 1.0) < Eps

  # Adding multiple IPs with shared prefixes should reduce the resulting ipScore for that prefix.
  test "ipScore decreases after inserting similar IPs":
    var tree = mkTree(["192.168.1.1", "192.168.1.2", "192.168.1.3"])
    let score = tree.ipScore(mkIp("192.168.1.4"))
    check score < 1.0

  # ipScore changes in response to insertions and removals of related IPs.
  test "ipScore handles multiple inserts and removals":
    var tree = mkTree(["10.0.0.1", "10.0.0.2"])
    let base = tree.ipScore(mkIp("10.0.0.3"))

    tree.insertIp(mkIp("10.0.0.3"))
    let afterInsert = tree.ipScore(mkIp("10.0.0.3"))

    tree.removeIp(mkIp("10.0.0.3"))
    let afterRemove = tree.ipScore(mkIp("10.0.0.3"))

    check afterInsert <= base
    check abs(afterRemove - base) < 1e-6

  # ipScore is always within [0, 1] for any input.
  test "ipScore is bounded between 0 and 1":
    var tree = mkTree(["192.168.1.1"])
    let score = tree.ipScore(mkIp("192.168.1.2"))
    check score >= 0.0
    check score <= 1.0

  # Different insert distributions should yield different scores for the same query IP.
  test "ipScore changes with different inserted IPs":
    var tree1 = mkTree(["192.168.1.1"])
    let score1 = tree1.ipScore(mkIp("192.168.1.2"))

    var tree2 = mkTree(["10.0.0.1"])
    let score2 = tree2.ipScore(mkIp("192.168.1.2"))

    check abs(score1 - score2) > 0.0001

  # Removing an IP that was previously inserted should not raise or crash.
  test "removeIp on inserted IP does not crash":
    var tree = IpTree.new()
    let ip = mkIp("1.2.3.4")
    tree.insertIp(ip)
    tree.removeIp(ip)
    check tree.root.counter == 0

  # If an advertisement has no IPv4 multiaddrs, adScore is 1.0 by definition.
  test "adScore returns 1.0 when advertisement has no IPv4 addresses":
    let tree = IpTree.new()
    let ad = mkAd(["/dns4/example.com/tcp/4001"])
    let score = tree.adScore(ad)
    check abs(score - 1.0) < Eps

  # adScore equals the minimum ipScore among all IPv4 addresses present in the advertisement.
  test "adScore uses the minimum ipScore among the ad's IPv4 addresses":
    var tree = mkTree(["192.168.1.1", "192.168.1.2"])
    let ad = mkAd([
      "/ip4/192.168.1.3/tcp/4001",
      "/ip4/10.0.0.1/tcp/4001"
    ])

    let score = tree.adScore(ad)
    let expected = min(
      tree.ipScore(mkIp("192.168.1.3")),
      tree.ipScore(mkIp("10.0.0.1"))
    )

    check abs(score - expected) < Eps

  # adScore should safely ignore non-ip4 addrs, and still consider any valid IPv4 addrs.
  test "adScore ignores non-ip4 multiaddrs and does not crash":
    var tree = mkTree(["192.168.1.1"])
    let ad = mkAd([
      "/dns4/example.com/tcp/4001",
      "/ip4/192.168.1.2/tcp/4001",
      "/ip6/2001:db8::1/tcp/4001"
    ])

    let score = tree.adScore(ad)
    check score <= 1.0
    check score >= 0.0

  # ipScore is computed as an integer count of flagged levels divided by 32.
  test "ipScore is quantized in 1/32 steps":
    var tree = mkTree(["192.168.1.1", "192.168.1.2", "10.0.0.1"])
    let score = tree.ipScore(mkIp("192.168.1.3"))
    let scaled = score * 32.0
    check abs(scaled - round(scaled)) < 1e-6

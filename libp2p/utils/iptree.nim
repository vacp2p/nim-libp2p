# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[net, math]

type
  IpTreeNode* = ref object
    counter*: int
    left*, right*: IpTreeNode

  IpTree* = ref object
    root*: IpTreeNode ## IPv4 tree root: a 32-level binary tree.
    root6*: IpTreeNode ## IPv6 tree root: a 128-level binary tree.

proc new*(T: typedesc[IpTree]): T =
  T(root: IpTreeNode(counter: 0), root6: IpTreeNode(counter: 0))

proc ipBytes(ip: IpAddress): seq[uint8] {.raises: [].} =
  case ip.family
  of IpAddressFamily.IPv4:
    @(ip.address_v4)
  of IpAddressFamily.IPv6:
    @(ip.address_v6)

proc treeRoot(ipTree: IpTree, ip: IpAddress): IpTreeNode =
  case ip.family
  of IpAddressFamily.IPv4: ipTree.root
  of IpAddressFamily.IPv6: ipTree.root6

proc insertIp*(ipTree: IpTree, ip: IpAddress) {.raises: [].} =
  ## Inserts an IP address into the IP tree, following its binary
  ## representation and incrementing counters at each visited node.
  ## IPv4 addresses walk the 32-level tree,
  ## IPv6 addresses walk the 128-level tree.
  var v = ipTree.treeRoot(ip)
  v.counter += 1

  let bytes = ip.ipBytes()

  for b in bytes:
    for bit in countdown(7, 0):
      let goRight = (b and (1'u8 shl bit)) != 0

      if goRight:
        if v.right.isNil:
          v.right = IpTreeNode(counter: 0)
        v = v.right
      else:
        if v.left.isNil:
          v.left = IpTreeNode(counter: 0)
        v = v.left

      v.counter += 1

proc removeIp*(ipTree: IpTree, ip: IpAddress) {.raises: [].} =
  ## Removes an IP address from the IP tree by decrementing counters along
  ## its binary-representation path. Counters never go below zero.
  let root = ipTree.treeRoot(ip)
  if root.counter == 0:
    return

  var v = root
  let bytes = ip.ipBytes()

  var path: array[128, IpTreeNode]
  var pathLen = 0

  for b in bytes:
    for bit in countdown(7, 0):
      if v.isNil or v.counter == 0:
        return

      path[pathLen] = v
      inc pathLen

      let goLeft = (b and (1'u8 shl bit)) == 0
      let nxt = if goLeft: v.left else: v.right
      if nxt.isNil:
        return
      v = nxt

  for j in 0 ..< pathLen:
    let n = path[j]
    if n.counter > 0:
      dec n.counter

proc ipScore*(ipTree: IpTree, ip: IpAddress): float64 {.raises: [].} =
  ## Returns an IP similarity score in [0.0, 1.0] for the given IP address.
  ## Supports both IPv4 (32-level tree) and IPv6 (128-level tree).
  ##
  ## The score counts how many of the prefix nodes along the IP's path have
  ## a counter exceeding the expected threshold (root.counter / 2^(depth+1)),
  ## where depth+1 is the tree level of the child node being evaluated.
  ## A high score means many existing IPs share the same subnet — a signal of
  ## Sybil-style clustering.
  let root = ipTree.treeRoot(ip)
  if root.counter == 0:
    return 0.0

  var v = root
  var score = 0
  let total = float64(root.counter)
  let bytes = ip.ipBytes()
  let nBits = bytes.len * 8

  var depth = 0
  for b in bytes:
    for bit in countdown(7, 0):
      let threshold = total / pow(2.0, float64(depth + 1))

      v = if (b and (1'u8 shl bit)) == 0: v.left else: v.right

      if v.isNil:
        return (float64(score) / float64(nBits))

      if float64(v.counter) > threshold:
        score += 1

      inc depth

  (float64(score) / float64(nBits))

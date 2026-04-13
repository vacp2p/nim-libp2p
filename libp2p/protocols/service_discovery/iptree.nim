# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/net
import results
import ./types

proc new*(T: typedesc[IpTree]): T =
  T(root: IpTreeNode(counter: 0))

proc insertIp*(ipTree: IpTree, ip: IpAddress): Result[void, string] {.raises: [].} =
  ## Adds an IPv4 address to the IP tree by incrementing counters along the
  ## 32-bit path. Only IPv4 is supported (the tree has exactly 32 levels).
  if ip.family != IpAddressFamily.IPv4:
    return err("insertIp: IPv6 not supported")

  var v = ipTree.root
  let bytes = ip.address_v4
  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0):
      v.counter += 1
      if (b and (1'u8 shl bit)) == 0:
        if v.left.isNil:
          v.left = IpTreeNode(counter: 0)
        v = v.left
      else:
        if v.right.isNil:
          v.right = IpTreeNode(counter: 0)
        v = v.right
  ok()

proc removeIp*(ipTree: IpTree, ip: IpAddress): Result[void, string] {.raises: [].} =
  ## Removes an IPv4 address from the IP tree by decrementing counters along
  ## the 32-bit path. Counters never go below zero. Only IPv4 is supported.
  if ip.family != IpAddressFamily.IPv4:
    return err("removeIp: IPv6 not supported")

  if ipTree.root.counter == 0:
    return ok()

  var v = ipTree.root
  let bytes = ip.address_v4

  var path: array[32, IpTreeNode]
  var pathLen = 0

  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0):
      if v.isNil or v.counter == 0:
        return ok()

      path[pathLen] = v
      inc pathLen

      let goLeft = (b and (1'u8 shl bit)) == 0
      let nxt = if goLeft: v.left else: v.right
      if nxt.isNil:
        return ok()
      v = nxt

  for j in 0 ..< pathLen:
    let n = path[j]
    if n.counter > 0:
      dec n.counter
  ok()

proc ipScore*(ipTree: IpTree, ip: IpAddress): Result[float64, string] {.raises: [].} =
  ## Returns an IP similarity score in [0.0, 1.0] for the given IPv4 address,
  ## or an error if the address family is not supported.
  ##
  ## The score counts how many of the 32 prefix nodes along the IP's path have
  ## a counter exceeding the expected threshold (root.counter / 2^(depth+1)),
  ## where depth+1 is the tree level of the child node being evaluated.
  ## A high score means many existing IPs share the same subnet — a signal of
  ## Sybil-style clustering.
  if ip.family != IpAddressFamily.IPv4:
    return err("ipScore: IPv6 not supported")

  if ipTree.root.counter == 0:
    return ok(0.0)

  var v = ipTree.root
  var score = 0
  let total = float64(ipTree.root.counter)
  let bytes = ip.address_v4

  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0):
      let depth = i * 8 + (7 - bit) # 0 .. 31; child node sits at tree level depth+1
      let threshold = total / float64(1'u64 shl (depth + 1))

      v = if (b and (1'u8 shl bit)) == 0: v.left else: v.right

      if v.isNil:
        return ok(float64(score) / 32.0)

      if float64(v.counter) > threshold:
        score += 1

  ok(float64(score) / 32.0)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[net]
import chronicles, results
import ./types

logScope:
  topics = "cap-disco iptree"

proc new*(T: typedesc[IpTree]): T =
  T(root: IpTreeNode(counter: 0))

proc insertIp*(ipTree: IpTree, ip: IpAddress): Result[void, string] {.raises: [].} =
  ## Adds an IPv4 address to the IP tree by incrementing counters along the 32-bit path.
  ## Only supports IPv4 (as per the RFC specification which defines a 32-level tree).
  if ip.family != IpAddressFamily.IPv4:
    return err("insertIp: IPv6 not supported")

  var v = ipTree.root
  let bytes = ip.address_v4

  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0): # MSB first
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
  if ip.family != IpAddressFamily.IPv4:
    return err("removeIp: IPv6 not supported")

  var v = ipTree.root
  let bytes = ip.address_v4

  if v.counter == 0:
    return ok()

  var path: array[32, IpTreeNode]
  var pathLen = 0

  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0):
      if v.isNil or v.counter == 0:
        return ok()

      path[pathLen] = v
      inc pathLen

      let goLeft = ((b and (1'u8 shl bit)) == 0)
      let nxt = (if goLeft: v.left else: v.right)
      if nxt.isNil:
        return ok()
      v = nxt

  for j in 0 ..< pathLen:
    let n = path[j]
    if n.counter > 0:
      dec n.counter
  ok()

proc insertAd*(ipTree: IpTree, ad: Advertisement): Result[void, string] {.raises: [].} =
  for addressInfo in ad.data.addresses:
    let multiAddr = addressInfo.address
    let ip = multiAddr.getIp().valueOr:
      continue
    if ip.family != IpAddressFamily.IPv4:
      continue
    ?ipTree.insertIp(ip)
  ok()

proc removeAd*(ipTree: IpTree, ad: Advertisement): Result[void, string] {.raises: [].} =
  for addressInfo in ad.data.addresses:
    let multiAddr = addressInfo.address
    let ip = multiAddr.getIp().valueOr:
      continue
    if ip.family != IpAddressFamily.IPv4:
      continue
    ?ipTree.removeIp(ip)
  ok()

proc ipScore*(ipTree: IpTree, ip: IpAddress): float64 {.raises: [].} =
  ## Calculates the IP similarity score (0.0 to 1.0) for the given IPv4 address
  ## based on how many prefix nodes have more than half the expected count.
  ## Returns a value in [0.0, 1.0].

  if ip.family != IpAddressFamily.IPv4:
    error "Cannot score Ipv6 addr"
    return 0.0

  if ipTree.root.counter == 0:
    return 0.0

  var v = ipTree.root
  var score = 0
  let bytes = ip.address_v4
  let total = float64(ipTree.root.counter)

  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0):
      let depth = i * 8 + (7 - bit) # depth from 0 to 31
      let threshold = total / float64(1 shl depth) # root.counter / 2^depth

      if (b and (1'u8 shl bit)) == 0:
        v = v.left
      else:
        v = v.right

      if v.isNil:
        # Should not happen if tree is consistent, but safe fallback
        return float64(score) / 32.0

      if float64(v.counter) > threshold:
        score += 1

  return float64(score) / 32.0

proc adScore*(ipTree: IpTree, ad: Advertisement): float64 {.raises: [].} =
  ## Return the max score for this advertisment

  var maxScore = 0.0
  for addressInfo in ad.data.addresses:
    let multiAddr = addressInfo.address
    let ip = multiAddr.getIp().valueOr:
      continue

    let score = ipTree.ipScore(ip)
    if score > maxScore:
      maxScore = score

  return maxScore

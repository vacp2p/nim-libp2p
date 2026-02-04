# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[net]
import results
import ./types

type IpTreeError* = enum
  Ipv4Required = "IPv4 address required"

proc new*(T: typedesc[IpTree]): T =
  T(root: IpTreeNode(counter: 0))

proc insertIp*(ipTree: IpTree, ip: IpAddress): Result[void, IpTreeError] =
  ## Adds an IPv4 address to the IP tree by incrementing counters along the 32-bit path.
  ## Only supports IPv4 (as per the RFC specification which defines a 32-level tree).
  if ip.family != IpAddressFamily.IPv4:
    return err(Ipv4Required)

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

proc removeIp*(ipTree: IpTree, ip: IpAddress): Result[void, IpTreeError] =
  ## Removes an IPv4 address from the IP tree by decrementing counters along the 32-bit path.
  ## Only supports IPv4.
  if ip.family != IpAddressFamily.IPv4:
    return err(Ipv4Required)

  var v = ipTree.root
  let bytes = ip.address_v4

  for i in 0 ..< 4:
    let b = bytes[i]
    for bit in countdown(7, 0):
      v.counter -= 1
      if (b and (1'u8 shl bit)) == 0:
        v = v.left
      else:
        v = v.right
  ok()

proc ipScore*(ipTree: IpTree, ip: IpAddress): Result[float64, IpTreeError] =
  ## Calculates the IP similarity score (0.0 to 1.0) for the given IPv4 address
  ## based on how many prefix nodes have more than half the expected count.
  ## Returns a value in [0.0, 1.0].
  if ip.family != IpAddressFamily.IPv4:
    return err(Ipv4Required)

  if ipTree.root.counter == 0:
    return ok(0.0)

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
        return ok(float64(score) / 32.0)

      if float64(v.counter) > threshold:
        score += 1

  return ok(float64(score) / 32.0)

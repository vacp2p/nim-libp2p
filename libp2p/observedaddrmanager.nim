# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[sequtils, tables, sugar]
import chronos
import multiaddress, multicodec

const
  DefaultObservedAddrMaxSize* = 10
  DefaultObservedAddrMinCount* = 3

type
  ObservedAddrManagerConfig* = object
    maxSize*: int = DefaultObservedAddrMaxSize
    minCount*: int = DefaultObservedAddrMinCount

  ObservedAddrManagerState = enum
    Fresh ## accepts observations: a manager seeded before the start is valid
    Started
    Stopped

  ObservedAddrManager* = ref object of RootObj
    observedIPsAndPorts: seq[MultiAddress]
    maxSize: int
    minCount: int
    state: ObservedAddrManagerState

func namesDialableAddr(observedAddr: MultiAddress): bool =
  # a remote peer picks what it reports, and the window holds maxSize entries,
  # so an address which no getter can return would only evict a useful one
  let code = (observedAddr[0].flatMap(protoCode)).valueOr:
    return false
  if code != multiCodec("ip4") and code != multiCodec("ip6"):
    return false
  observedAddr.len().get(0) > 1

proc addObservation*(self: ObservedAddrManager, observedAddr: MultiAddress): bool =
  ## Adds a new observed MultiAddress. If the number of observations exceeds maxSize, the oldest one is removed.
  ## Returns false when the manager is stopped, or when the address names no dialable address.
  if self.state == Stopped:
    return false
  if not observedAddr.namesDialableAddr():
    return false
  if self.observedIPsAndPorts.len >= self.maxSize:
    self.observedIPsAndPorts.del(0)
  self.observedIPsAndPorts.add(observedAddr)
  true

proc getProtocol(
    self: ObservedAddrManager, observations: seq[MultiAddress], multiCodec: MultiCodec
): Opt[MultiAddress] =
  var countTable = toCountTable(observations)
  countTable.sort()
  var orderedPairs = toSeq(countTable.pairs)
  for (ma, count) in orderedPairs:
    let protoCode = (ma[0].flatMap(protoCode)).valueOr:
      continue
    if protoCode == multiCodec and count >= self.minCount:
      return Opt.some(ma)
  return Opt.none(MultiAddress)

proc getMostObservedProtocol(
    self: ObservedAddrManager, multiCodec: MultiCodec
): Opt[MultiAddress] =
  ## Returns the most observed IP address or none if the number of observations are less than minCount.
  let observedIPs = collect:
    for observedIp in self.observedIPsAndPorts:
      observedIp[0].valueOr:
        continue
  return self.getProtocol(observedIPs, multiCodec)

proc getMostObservedProtoAndPort(
    self: ObservedAddrManager, multiCodec: MultiCodec
): Opt[MultiAddress] =
  ## Returns the most observed IP/Port address or none if the number of observations are less than minCount.
  return self.getProtocol(self.observedIPsAndPorts, multiCodec)

proc getMostObservedProtosAndPorts*(self: ObservedAddrManager): seq[MultiAddress] =
  ## Returns the most observed IP4/Port and IP6/Port address or an empty seq if the number of observations
  ## are less than minCount.
  var res: seq[MultiAddress]
  self.getMostObservedProtoAndPort(multiCodec("ip4")).withValue(ip4):
    res.add(ip4)
  self.getMostObservedProtoAndPort(multiCodec("ip6")).withValue(ip6):
    res.add(ip6)
  return res

proc guessDialableAddr*(self: ObservedAddrManager, ma: MultiAddress): MultiAddress =
  ## Replaces the first proto value of each listen address by the corresponding (matching the proto code) most observed value.
  ## If the most observed value is not available, the original MultiAddress is returned.
  let
    maFirst = ma[0].valueOr:
      return ma
    maRest = ma[1 ..^ 1].valueOr:
      return ma
    maFirstProto = maFirst.protoCode().valueOr:
      return ma

  let observedIP = self.getMostObservedProtocol(maFirstProto).valueOr:
    return ma
  return concat(observedIP, maRest).valueOr:
    ma

func isStarted*(self: ObservedAddrManager): bool =
  self.state == Started

proc start*(self: ObservedAddrManager) {.async: (raises: [CancelledError]).} =
  if self.state == Started:
    return
  self.state = Started

proc stop*(self: ObservedAddrManager) {.async: (raises: [CancelledError]).} =
  if self.state != Started:
    return
  self.state = Stopped
  self.observedIPsAndPorts.setLen(0)

proc `$`*(self: ObservedAddrManager): string =
  ## Returns a string representation of the ObservedAddrManager.
  return "IPs and Ports: " & $self.observedIPsAndPorts

proc new*(
    T: typedesc[ObservedAddrManager],
    maxSize = DefaultObservedAddrMaxSize,
    minCount = DefaultObservedAddrMinCount,
): T =
  return
    T(observedIPsAndPorts: newSeq[MultiAddress](), maxSize: maxSize, minCount: minCount)

proc new*(T: typedesc[ObservedAddrManager], config: ObservedAddrManagerConfig): T =
  ## Creates a new ObservedAddrManager from a switch-level config.
  T.new(maxSize = config.maxSize, minCount = config.minCount)

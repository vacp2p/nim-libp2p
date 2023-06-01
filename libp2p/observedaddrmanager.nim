# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[sequtils, tables],
  chronos, chronicles,
  multiaddress, multicodec

type
  ## Manages observed MultiAddresses by reomte peers. It keeps track of the most observed IP and IP/Port.
  ObservedAddrManager* = ref object of RootObj
    observedIPsAndPorts: seq[MultiAddress]
    maxSize: int
    minCount: int

proc addObservation*(self:ObservedAddrManager, observedAddr: MultiAddress): bool =
  ## Adds a new observed MultiAddress. If the number of observations exceeds maxSize, the oldest one is removed.
  if self.observedIPsAndPorts.len >= self.maxSize:
      self.observedIPsAndPorts.del(0)
  self.observedIPsAndPorts.add(observedAddr)
  return true

proc getProtocol(self: ObservedAddrManager, observations: seq[MultiAddress], multiCodec: MultiCodec): Opt[MultiAddress] =
  var countTable = toCountTable(observations)
  countTable.sort()
  var orderedPairs = toSeq(countTable.pairs)
  for (ma, count) in orderedPairs:
    let maFirst = ma[0].valueOr(continue)
    if maFirst.protoCode.valueOr(continue) == multiCodec and count >= self.minCount:
      return Opt.some(ma)
  return Opt.none(MultiAddress)

proc getMostObservedProtocol(self: ObservedAddrManager, multiCodec: MultiCodec): Opt[MultiAddress] =
  ## Returns the most observed IP address or none if the number of observations are less than minCount.
  let observedIPs = collect:
    for observedIp in self.observedIPsAndPorts:
      observedIp.valueOr(continue)
  return self.getProtocol(observedIPs, multiCodec)

proc getMostObservedProtoAndPort(self: ObservedAddrManager, multiCodec: MultiCodec): Opt[MultiAddress] =
  ## Returns the most observed IP/Port address or none if the number of observations are less than minCount.
  return self.getProtocol(self.observedIPsAndPorts, multiCodec)

proc getMostObservedProtosAndPorts*(self: ObservedAddrManager): seq[MultiAddress] =
  ## Returns the most observed IP4/Port and IP6/Port address or an empty seq if the number of observations
  ## are less than minCount.
  var res: seq[MultiAddress]
  let ip4 = self.getMostObservedProtoAndPort(multiCodec("ip4"))
  block t:
    res.add(ip4.valueOr(break t))
  let ip6 = self.getMostObservedProtoAndPort(multiCodec("ip6"))
  block t:
    res.add(ip6.valueOr(break t))
  return res

proc guessDialableAddr*(
  self: ObservedAddrManager,
  ma: MultiAddress): MultiAddress =
  ## Replaces the first proto valeu of each listen address by the corresponding (matching the proto code) most observed value.
  ## If the most observed value is not available, the original MultiAddress is returned.
  let
    maFirst = ma[0].valueOr(return ma)
    maRest = ma[1..^1].valueOr(return ma)
    maFirstProto = maFirst.protoCode().valueOr(return ma)

  let observedIP = self.getMostObservedProtocol(maFirstProto).valueOr(return ma)
  return observedIP & maRest

proc `$`*(self: ObservedAddrManager): string =
  ## Returns a string representation of the ObservedAddrManager.
  return "IPs and Ports: " & $self.observedIPsAndPorts

proc new*(
  T: typedesc[ObservedAddrManager],
  maxSize = 10,
  minCount = 3): T =
  ## Creates a new ObservedAddrManager.
  return T(
    observedIPsAndPorts: newSeq[MultiAddress](),
    maxSize: maxSize,
    minCount: minCount)

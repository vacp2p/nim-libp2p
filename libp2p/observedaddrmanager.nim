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
  chronos,
  ./multiaddress

type
  ## Manages observed MultiAddresses by reomte peers. It keeps track of the most observed IP and IP/Port.
  ObservedAddrManager* = ref object of RootObj
    observedIPs: seq[MultiAddress]
    observedIPsAndPorts: seq[MultiAddress]
    maxSize: int
    minCount: int

proc add(self:ObservedAddrManager, observations: var seq[MultiAddress], observedAddr: MultiAddress) =
  if observations.len >= self.maxSize:
    observations.del(0)

  observations.add(observedAddr)

proc add*(self:ObservedAddrManager, observedAddr: MultiAddress) =
  ## Adds a new observed MultiAddress. If the MultiAddress already exists, the count is increased.
  self.add(self.observedIPs, observedAddr[0].get())
  self.add(self.observedIPsAndPorts, observedAddr)

proc getIP(self: ObservedAddrManager, observations: seq[MultiAddress], ipVersion: MaPattern): Opt[MultiAddress] =
  var countTable = toCountTable(observations)
  countTable.sort()
  var orderedPairs = toSeq(countTable.pairs)
  for maAndCount in orderedPairs:
    let ma = maAndCount[0]
    let ip = ma[0].get()
    let count = maAndCount[1]
    if ipVersion.match(ip) and count >= self.minCount:
      return Opt.some(ma)
  return Opt.none(MultiAddress)

proc getMostObservedIP6*(self: ObservedAddrManager): Opt[MultiAddress] =
  ## Returns the most observed IP6 address or none if the number of observations are less than minCount.
  return self.getIP(self.observedIPs, IP6)

proc getMostObservedIP4*(self: ObservedAddrManager): Opt[MultiAddress] =
  ## Returns the most observed IP4 address or none if the number of observations are less than minCount.
  return self.getIP(self.observedIPs, IP4)

proc getMostObservedIP6AndPort*(self: ObservedAddrManager): Opt[MultiAddress] =
  ## Returns the most observed IP6/Port address or none if the number of observations are less than minCount.
  return self.getIP(self.observedIPsAndPorts, IP6)

proc getMostObservedIP4AndPort*(self: ObservedAddrManager): Opt[MultiAddress] =
  ## Returns the most observed IP4/Port address or none if the number of observations are less than minCount.
  return self.getIP(self.observedIPsAndPorts, IP4)

proc getMostObservedIPsAndPorts*(self: ObservedAddrManager): seq[MultiAddress] =
  ## Returns the most observed IP4/Port and IP6/Port address or an empty seq if the number of observations
  ## are less than minCount.
  var res: seq[MultiAddress]
  if self.getMostObservedIP4().isSome():
    res.add(self.getMostObservedIP4().get())
  if self.getMostObservedIP6().isSome():
    res.add(self.getMostObservedIP6().get())
  return res

proc `$`*(self: ObservedAddrManager): string =
  ## Returns a string representation of the ObservedAddrManager.
  return "IPs: " & $self.observedIPs & "; IPs and Ports: " & $self.observedIPsAndPorts

proc new*(
  T: typedesc[ObservedAddrManager],
  maxSize = 10,
  minCount = 3): T =
  ## Creates a new ObservedAddrManager.
  return T(
    observedIPs: newSeq[MultiAddress](),
    observedIPsAndPorts: newSeq[MultiAddress](),
    maxSize: maxSize,
    minCount: minCount)

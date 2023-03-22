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
  multiaddress

type
  ## Manages observed MultiAddresses by reomte peers. It keeps track of the most observed IP and IP/Port.
  ObservedAddrManager* = ref object of RootObj
    observedIPsAndPorts: seq[MultiAddress]
    maxSize: int
    minCount: int

proc addObservation*(self:ObservedAddrManager, observedAddr: MultiAddress) =
  ## Adds a new observed MultiAddress. If the number of observations exceeds maxSize, the oldest one is removed.
  ## Both IP and IP/Port are tracked.
  if self.observedIPsAndPorts.len >= self.maxSize:
      self.observedIPsAndPorts.del(0)
  self.observedIPsAndPorts.add(observedAddr)

proc getIP(self: ObservedAddrManager, observations: seq[MultiAddress], ipVersion: MaPattern): Opt[MultiAddress] =
  var countTable = toCountTable(observations)
  countTable.sort()
  var orderedPairs = toSeq(countTable.pairs)
  for (ma, count) in orderedPairs:
    let ip = ma[0].get()
    if ipVersion.match(ip) and count >= self.minCount:
      return Opt.some(ma)
  return Opt.none(MultiAddress)

proc getMostObservedIP*(self: ObservedAddrManager, ipAddressFamily: IpAddressFamily): Opt[MultiAddress] =
  ## Returns the most observed IP address or none if the number of observations are less than minCount.
  let observedIPs = self.observedIPsAndPorts.mapIt(it[0].get())
  return self.getIP(observedIPs, if ipAddressFamily == IpAddressFamily.IPv4: IP4 else: IP6)

proc getMostObservedIPAndPort*(self: ObservedAddrManager, ipAddressFamily: IpAddressFamily): Opt[MultiAddress] =
  ## Returns the most observed IP/Port address or none if the number of observations are less than minCount.
  return self.getIP(self.observedIPsAndPorts, if ipAddressFamily == IpAddressFamily.IPv4: IP4 else: IP6)

proc getMostObservedIPsAndPorts*(self: ObservedAddrManager): seq[MultiAddress] =
  ## Returns the most observed IP4/Port and IP6/Port address or an empty seq if the number of observations
  ## are less than minCount.
  var res: seq[MultiAddress]
  let ip4 = self.getMostObservedIPAndPort(IpAddressFamily.IPv4)
  if ip4.isSome():
    res.add(ip4.get())
  let ip6 = self.getMostObservedIPAndPort(IpAddressFamily.IPv4)
  if ip6.isSome():
    res.add(ip6.get())
  return res

proc replaceMAIpByMostObserved*(
  self: ObservedAddrManager,
  ma: MultiAddress): Opt[MultiAddress] =
  try:
    let maIP = ma[0]
    let maWithoutIP = ma[1..^1]

    if maWithoutIP.isErr():
      return Opt.none(MultiAddress)

    let observedIP =
      if IP4.match(maIP.get()):
        self.getMostObservedIP(IpAddressFamily.IPv4)
      else:
        self.getMostObservedIP(IpAddressFamily.IPv6)

    let newMA =
      if observedIP.isNone() or maIP.get() == observedIP.get():
        ma
      else:
        observedIP.get() & maWithoutIP.get()

    return Opt.some(newMA)
  except CatchableError as error:
    debug "Error while handling manual port forwarding", msg = error.msg
    return Opt.none(MultiAddress)

proc guessDialableAddrs*(self: ObservedAddrManager, listenAddrs: seq[MultiAddress]): seq[MultiAddress] =
  for l in listenAddrs:
    let guess = self.replaceMAIpByMostObserved(l)
    if guess.isSome():
      result.add(guess.get())

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

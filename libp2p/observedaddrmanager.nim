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
    let maFirst = ma[0].get()
    if maFirst.protoCode.get() == multiCodec and count >= self.minCount:
      return Opt.some(ma)
  return Opt.none(MultiAddress)

proc getMostObservedProtocol(self: ObservedAddrManager, multiCodec: MultiCodec): Opt[MultiAddress] =
  ## Returns the most observed IP address or none if the number of observations are less than minCount.
  let observedIPs = self.observedIPsAndPorts.mapIt(it[0].get())
  return self.getProtocol(observedIPs, multiCodec)

proc getMostObservedProtoAndPort(self: ObservedAddrManager, multiCodec: MultiCodec): Opt[MultiAddress] =
  ## Returns the most observed IP/Port address or none if the number of observations are less than minCount.
  return self.getProtocol(self.observedIPsAndPorts, multiCodec)

proc getMostObservedProtosAndPorts*(self: ObservedAddrManager): seq[MultiAddress] =
  ## Returns the most observed IP4/Port and IP6/Port address or an empty seq if the number of observations
  ## are less than minCount.
  var res: seq[MultiAddress]
  let ip4 = self.getMostObservedProtoAndPort(multiCodec("ip4"))
  if ip4.isSome():
    res.add(ip4.get())
  let ip6 = self.getMostObservedProtoAndPort(multiCodec("ip6"))
  if ip6.isSome():
    res.add(ip6.get())
  return res

proc replaceProtoValueByMostObserved*(
  self: ObservedAddrManager,
  ma: MultiAddress): Opt[MultiAddress] =
  try:
    let maFirst = ma[0]
    let maWithoutIP = ma[1..^1]

    if maWithoutIP.isErr():
      return Opt.none(MultiAddress)

    let observedIP = self.getMostObservedProtocol(maFirst.get().protoCode().get())

    let newMA =
      if observedIP.isNone() or maFirst.get() == observedIP.get():
        ma
      else:
        observedIP.get() & maWithoutIP.get()

    return Opt.some(newMA)
  except CatchableError as error:
    debug "Error while handling manual port forwarding", msg = error.msg
    return Opt.none(MultiAddress)

proc guessDialableAddrs*(self: ObservedAddrManager, listenAddrs: seq[MultiAddress]): seq[MultiAddress] =
  for l in listenAddrs:
    let guess = self.replaceProtoValueByMostObserved(l)
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

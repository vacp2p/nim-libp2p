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

proc guessDialableAddr*(
  self: ObservedAddrManager,
  ma: MultiAddress): MultiAddress =
  ## Replaces the first proto valeu of each listen address by the corresponding (matching the proto code) most observed value.
  ## If the most observed value is not available, the original MultiAddress is returned.
  try:
    let maFirst = ma[0]
    let maRest = ma[1..^1]
    if maRest.isErr():
      return ma

    let observedIP = self.getMostObservedProtocol(maFirst.get().protoCode().get())
    return
      if observedIP.isNone() or maFirst.get() == observedIP.get():
        ma
      else:
        observedIP.get() & maRest.get()
  except CatchableError as error:
    debug "Error while handling manual port forwarding", msg = error.msg
    return ma

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

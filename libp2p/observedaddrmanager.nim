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
  std/[sets, options, heapqueue],
  chronos,
  ./crypto/crypto,
  ./protocols/identify,
  ./protocols/protocol,
  ./peerid, ./peerinfo,
  ./routing_record,
  ./multiaddress,
  ./stream/connection,
  ./multistream,
  ./muxers/muxer,
  utility

type
  ObservedAddr = object
    ma: MultiAddress
    count: int

  ## Manages observed MultiAddresses by reomte peers. It keeps track of the most observed IP and IP/Port.
  ObservedAddrManager* = ref object of RootObj
    observedIPs: HeapQueue[ObservedAddr]
    observedIPsAndPorts: HeapQueue[ObservedAddr]
    maxSize: int
    minCount: int

proc `<`(a, b: ObservedAddr): bool = a.count < b.count

proc add(self:ObservedAddrManager, heap: var HeapQueue[ObservedAddr], observedAddr: MultiAddress) =
  if heap.len >= self.maxSize:
    discard heap.pop()

  for i in 0 ..< heap.len:
    if heap[i].ma == observedAddr:
      let count = heap[i].count
      heap.del(i)
      heap.push(ObservedAddr(ma: observedAddr, count: count + 1))
      return

  heap.push(ObservedAddr(ma: observedAddr, count: 1))

proc add*(self:ObservedAddrManager, observedAddr: MultiAddress) =
  ## Adds a new observed MultiAddress. If the MultiAddress already exists, the count is increased.
  self.add(self.observedIPs, observedAddr[0].get())
  self.add(self.observedIPsAndPorts, observedAddr)

proc getIP(self: ObservedAddrManager, heap: HeapQueue[ObservedAddr], ipVersion: MaPattern): Opt[MultiAddress] =
  var i = 1
  while heap.len - i >= 0:
    let observedAddr = heap[heap.len - i]
    if ipVersion.match(observedAddr.ma[0].get()) and observedAddr.count >= self.minCount:
      return Opt.some(observedAddr.ma)
    else:
      i = i + 1
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
    observedIPs: initHeapQueue[ObservedAddr](),
    observedIPsAndPorts: initHeapQueue[ObservedAddr](),
    maxSize: maxSize,
    minCount: minCount)

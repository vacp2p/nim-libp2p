# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Stores generic informations about peers.
runnableExamples:
  # Will keep info of all connected peers +
  # last 50 disconnected peers
  let peerStore = PeerStore.new(capacity = 50)

  # Create a custom book type
  type MoodBook = ref object of PeerBook[string]

  var somePeerId = PeerId.random().get()

  peerStore[MoodBook][somePeerId] = "Happy"
  doAssert peerStore[MoodBook][somePeerId] == "Happy"

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/[tables, sets, options, macros, heapqueue],
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
  ObservedMA = object
    ma: MultiAddress
    count: int

  ObservedMAManager* = ref object of RootObj
    observedIPs: HeapQueue[ObservedMA]
    observedIPsAndPorts: HeapQueue[ObservedMA]
    maxSize: int
    minCount: int

proc `<`(a, b: ObservedMA): bool = a.count < b.count
proc `==`(a, b: ObservedMA): bool = a.ma == b.ma

proc add*(self:ObservedMAManager, heap: var HeapQueue[ObservedMA], observedMA: MultiAddress) =
  if heap.len >= self.maxSize:
    discard heap.pop()

  let idx = heap.find(ObservedMA(ma: observedMA, count: 0))
  if idx >= 0:
    let observedMA = heap[idx]
    heap.del(idx)
    heap.push(ObservedMA(ma: observedMA.ma, count: observedMA.count + 1))
  else:
    heap.push(ObservedMA(ma: observedMA, count: 1))

proc add*(self:ObservedMAManager, observedMA: MultiAddress) =
  self.add(self.observedIPs, observedMA[0].get())
  self.add(self.observedIPsAndPorts, observedMA)

proc getIP(self: ObservedMAManager, heap: HeapQueue[ObservedMA], ipVersion: MaPattern): Opt[MultiAddress] =
  var i = 1
  while heap.len - i >= 0:
    let observedMA = heap[heap.len - i]
    if ipVersion.match(observedMA.ma[0].get()) and observedMA.count >= self.minCount:
      return Opt.some(observedMA.ma)
    else:
      i = i + 1
  return Opt.none(MultiAddress)

proc getIP6*(self: ObservedMAManager): Opt[MultiAddress] =
  ## Returns the most observed IP6 address
  return self.getIP(self.observedIPs, IP6)

proc getIP4*(self: ObservedMAManager): Opt[MultiAddress] =
  ## Returns the most observed IP4 address
  return self.getIP(self.observedIPs, IP4)

proc getIP6AndPort*(self: ObservedMAManager): Opt[MultiAddress] =
  ## Returns the most observed IP6 address
  return self.getIP(self.observedIPsAndPorts, IP6)

proc getIP4AndPort*(self: ObservedMAManager): Opt[MultiAddress] =
  ## Returns the most observed IP4 address
  return self.getIP(self.observedIPsAndPorts, IP4)

proc getIPsAndPorts*(self: ObservedMAManager): seq[MultiAddress] =
  ## Returns the most observed IP4 and IP6 address
  var res: seq[MultiAddress]
  if self.getIP4().isSome():
    res.add(self.getIP4().get())
  if self.getIP6().isSome():
    res.add(self.getIP6().get())
  return res

proc `$`*(self: ObservedMAManager): string =
  return "IPs: " & $self.observedIPs & "; IPs and Ports: " & $self.observedIPsAndPorts

proc new*(
  T: typedesc[ObservedMAManager]): T =
  return T(
    observedIPs: initHeapQueue[ObservedMA](),
    observedIPsAndPorts: initHeapQueue[ObservedMA](),
    maxSize: 10,
    minCount: 3)

type
  #################
  # Handler types #
  #################

  PeerBookChangeHandler* = proc(peerId: PeerId) {.gcsafe, raises: [Defect].}

  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  BasePeerBook = ref object of RootObj
    changeHandlers: seq[PeerBookChangeHandler]
    deletor: PeerBookChangeHandler

  PeerBook*[T] {.public.} = ref object of BasePeerBook
    book*: Table[PeerId, T]

  SeqPeerBook*[T] = ref object of PeerBook[seq[T]]

  AddressBook* {.public.} = ref object of SeqPeerBook[MultiAddress]
  ProtoBook* {.public.} = ref object of SeqPeerBook[string]
  KeyBook* {.public.} = ref object of PeerBook[PublicKey]

  AgentBook* {.public.} = ref object of PeerBook[string]
  ProtoVersionBook* {.public.} = ref object of PeerBook[string]
  SPRBook* {.public.} = ref object of PeerBook[Envelope]

  ####################
  # Peer store types #
  ####################

  PeerStore* {.public.} = ref object
    books: Table[string, BasePeerBook]
    identify: Identify
    capacity*: int
    toClean*: seq[PeerId]
    observedMAManager*: ObservedMAManager

proc new*(T: type PeerStore, identify: Identify, capacity = 1000): PeerStore {.public.} =
  T(
    identify: identify,
    capacity: capacity,
    observedMAManager: ObservedMAManager.new(),
  )

#########################
# Generic Peer Book API #
#########################

proc `[]`*[T](peerBook: PeerBook[T],
             peerId: PeerId): T {.public.} =
  ## Get all known metadata of a provided peer, or default(T) if missing
  peerBook.book.getOrDefault(peerId)

proc `[]=`*[T](peerBook: PeerBook[T],
             peerId: PeerId,
             entry: T) {.public.} =
  ## Set metadata for a given peerId.

  peerBook.book[peerId] = entry

  # Notify clients
  for handler in peerBook.changeHandlers:
    handler(peerId)

proc del*[T](peerBook: PeerBook[T],
                peerId: PeerId): bool {.public.} =
  ## Delete the provided peer from the book. Returns whether the peer was in the book

  if peerId notin peerBook.book:
    return false
  else:
    peerBook.book.del(peerId)
    # Notify clients
    for handler in peerBook.changeHandlers:
      handler(peerId)
    return true

proc contains*[T](peerBook: PeerBook[T], peerId: PeerId): bool {.public.} =
  peerId in peerBook.book

proc addHandler*[T](peerBook: PeerBook[T], handler: PeerBookChangeHandler) {.public.} =
  ## Adds a callback that will be called everytime the book changes
  peerBook.changeHandlers.add(handler)

proc len*[T](peerBook: PeerBook[T]): int {.public.} = peerBook.book.len

##################
# Peer Store API #
##################
macro getTypeName(t: type): untyped =
  # Generate unique name in form of Module.Type
  let typ = getTypeImpl(t)[1]
  newLit(repr(typ.owner()) & "." & repr(typ))

proc `[]`*[T](p: PeerStore, typ: type[T]): T {.public.} =
  ## Get a book from the PeerStore (ex: peerStore[AddressBook])
  let name = getTypeName(T)
  result = T(p.books.getOrDefault(name))
  if result.isNil:
    result = T.new()
    result.deletor = proc(pid: PeerId) =
      # Manual method because generic method
      # don't work
      discard T(p.books.getOrDefault(name)).del(pid)
    p.books[name] = result
  return result

proc del*(peerStore: PeerStore,
             peerId: PeerId) {.public.} =
  ## Delete the provided peer from every book.
  for _, book in peerStore.books:
    book.deletor(peerId)

proc updatePeerInfo*(
  peerStore: PeerStore,
  info: IdentifyInfo) =

  if info.addrs.len > 0:
    peerStore[AddressBook][info.peerId] = info.addrs

  if info.pubkey.isSome:
    peerStore[KeyBook][info.peerId] = info.pubkey.get()

  if info.agentVersion.isSome:
    peerStore[AgentBook][info.peerId] = info.agentVersion.get().string

  if info.protoVersion.isSome:
    peerStore[ProtoVersionBook][info.peerId] = info.protoVersion.get().string

  if info.protos.len > 0:
    peerStore[ProtoBook][info.peerId] = info.protos

  if info.signedPeerRecord.isSome:
    peerStore[SPRBook][info.peerId] = info.signedPeerRecord.get()

  let cleanupPos = peerStore.toClean.find(info.peerId)
  if cleanupPos >= 0:
    peerStore.toClean.delete(cleanupPos)

proc cleanup*(
  peerStore: PeerStore,
  peerId: PeerId) =

  if peerStore.capacity == 0:
    peerStore.del(peerId)
    return
  elif peerStore.capacity < 0:
    #infinite capacity
    return

  peerStore.toClean.add(peerId)
  while peerStore.toClean.len > peerStore.capacity:
    peerStore.del(peerStore.toClean[0])
    peerStore.toClean.delete(0)

proc identify*(
  peerStore: PeerStore,
  muxer: Muxer) {.async.} =

  # new stream for identify
  var stream = await muxer.newStream()
  if stream == nil:
    return

  try:
    if (await MultistreamSelect.select(stream, peerStore.identify.codec())):
      let info = await peerStore.identify.identify(stream, stream.peerId)

      if info.observedAddr.isSome:
        peerStore.observedMAManager.add(info.observedAddr.get())

      when defined(libp2p_agents_metrics):
        var knownAgent = "unknown"
        if info.agentVersion.isSome and info.agentVersion.get().len > 0:
          let shortAgent = info.agentVersion.get().split("/")[0].safeToLowerAscii()
          if shortAgent.isOk() and KnownLibP2PAgentsSeq.contains(shortAgent.get()):
            knownAgent = shortAgent.get()
        muxer.connection.setShortAgent(knownAgent)

      peerStore.updatePeerInfo(info)
  finally:
    await stream.closeWithEOF()

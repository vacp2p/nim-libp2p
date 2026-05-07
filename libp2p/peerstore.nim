# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Stores generic informations about peers.
runnableExamples:
  # Will keep info of all connected peers +
  # last 50 disconnected peers
  # Passing `nil` for `identify` is only safe for simple peer-book usage like
  # this example. APIs that rely on identify metadata require a real
  # `Identify` instance when constructing the `PeerStore`.
  import libp2p/peerid

  let ps = PeerStore.new(nil, capacity = 50)

  # Create a custom book type
  type MoodBook = ref object of PeerBook[string]

  let exampleRng = newRng()
  var somePeerId = PeerId.random(exampleRng).expect("get random key")

  ps[MoodBook][somePeerId] = "Happy"
  doAssert ps[MoodBook][somePeerId] == "Happy"

{.push raises: [].}

import
  std/[tables, sets, macros, sequtils],
  chronos,
  ./utils/heartbeat,
  ./crypto/crypto,
  ./protocols/identify,
  ./protocols/protocol,
  ./peerid,
  ./peeraddrpolicy,
  ./peerinfo,
  ./routing_record,
  ./multiaddress,
  ./stream/connection,
  ./multistream,
  ./muxers/muxer,
  utility

type
  #################
  # Handler types #
  #################
  PeerBookChangeHandler* = proc(peerId: PeerId) {.gcsafe, raises: [].}

  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  BasePeerBook = ref object of RootObj
    changeHandlers: seq[PeerBookChangeHandler]
    deletor: PeerBookChangeHandler

  PeerBook*[T] = ref object of BasePeerBook
    book*: Table[PeerId, T]

  SeqPeerBook*[T] = ref object of PeerBook[seq[T]]

  AddressConfidence* = enum
    ## Received from a discovery mechanism (DHT, rendezvous, mDNS, etc.).
    ## Not yet verified by a direct connection. Short TTL: quickly discarded
    ## if the address is never used.
    Low
    ## Self-reported by the peer via identify/identify-push, or manually
    ## provided by the user. Not yet verified by a direct connection.
    ## Medium TTL: reasonably trusted but not confirmed reachable.
    Medium
    ## Verified: we successfully dialled this address at least once.
    ## Long TTL: high confidence that the address is reachable.
    High
    ## Never expires regardless of how long since the last update.
    Infinite

  AddressEntry* = object
    address*: MultiAddress
    confidence*: AddressConfidence
    lastUpdated*: Moment

  AddressConfidenceTtls* = object
    low*: Duration ## TTL for Low-confidence addresses (default 15 minutes)
    medium*: Duration ## TTL for Medium-confidence addresses (default 1 hour)
    high*: Duration ## TTL for High-confidence addresses (default 24 hours)

  AddressBook* = ref object of PeerBook[seq[AddressEntry]]
    ttls*: AddressConfidenceTtls

  KeyBook* = ref object of PeerBook[PublicKey]

  AgentBook* = ref object of PeerBook[string]
  LastSeenBook* = ref object of PeerBook[Opt[MultiAddress]]
  LastSeenOutboundBook* = ref object of PeerBook[Opt[MultiAddress]]
  ProtoVersionBook* = ref object of PeerBook[string]
  SPRBook* = ref object of PeerBook[Envelope]

  ####################
  # Peer store types #
  ####################
  PeerStore* = ref object
    books: Table[string, BasePeerBook]
    identify: Identify
    capacity*: int
    toClean*: seq[PeerId]
    addressPolicy*: PeerAddressPolicy
      ## When set, inbound peer addresses are filtered through the shared
      ## policy before they are stored or redistributed.
    addressTtls*: AddressConfidenceTtls ## Per-confidence TTLs for address expiry.
    pruneHandle: Future[void]

const defaultAddressConfidenceTtls* =
  AddressConfidenceTtls(low: 15.minutes, medium: 1.hours, high: 24.hours)

proc new*(
    Self: type PeerStore,
    identify: Identify,
    capacity = 1000,
    addressTtls = defaultAddressConfidenceTtls,
): PeerStore =
  # Self instead of T to avoid clashing with withValue[T]'s type param under --lineDir:on
  Self(
    identify: identify,
    capacity: capacity,
    addressPolicy: defaultAddressPolicy,
    addressTtls: addressTtls,
  )

#########################
# Generic Peer Book API #
#########################

proc `[]`*[T](peerBook: PeerBook[T], peerId: PeerId): T =
  ## Get all known metadata of a provided peer, or default(T) if missing
  peerBook.book.getOrDefault(peerId)

proc `[]=`*[T](peerBook: PeerBook[T], peerId: PeerId, entry: T) =
  ## Set metadata for a given peerId.

  peerBook.book[peerId] = entry

  # Notify clients
  for handler in peerBook.changeHandlers:
    handler(peerId)

proc del*[T](peerBook: PeerBook[T], peerId: PeerId): bool =
  ## Delete the provided peer from the book. Returns whether the peer was in the book

  if peerId notin peerBook.book:
    return false
  else:
    peerBook.book.del(peerId)
    # Notify clients
    for handler in peerBook.changeHandlers:
      handler(peerId)
    return true

proc contains*[T](peerBook: PeerBook[T], peerId: PeerId): bool =
  peerId in peerBook.book

proc addHandler*[T](peerBook: PeerBook[T], handler: PeerBookChangeHandler) =
  ## Adds a callback that will be called everytime the book changes
  peerBook.changeHandlers.add(handler)

proc len*[T](peerBook: PeerBook[T]): int =
  peerBook.book.len

################################
# AddressBook per-address TTLs #
################################

proc isExpired*(entry: AddressEntry, ttls: AddressConfidenceTtls): bool =
  let elapsed = Moment.now() - entry.lastUpdated
  case entry.confidence
  of AddressConfidence.Low:
    elapsed > ttls.low
  of AddressConfidence.Medium:
    elapsed > ttls.medium
  of AddressConfidence.High:
    elapsed > ttls.high
  of AddressConfidence.Infinite:
    false

proc set*(
    addressBook: AddressBook,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    confidence = AddressConfidence.Medium,
) =
  ## Replace the address list for `peerId`. For addresses that already exist
  ## the confidence is upgraded to `max(existing, confidence)` so that a
  ## high-confidence entry is never downgraded by a lower-confidence update.
  let now = Moment.now()
  var prevConf: Table[MultiAddress, AddressConfidence]
  for entry in addressBook.book.getOrDefault(peerId):
    prevConf[entry.address] = entry.confidence

  var newEntries = newSeqOfCap[AddressEntry](addrs.len)
  for ma in addrs:
    let conf =
      if ma in prevConf:
        max(prevConf[ma], confidence)
      else:
        confidence
    newEntries.add(AddressEntry(address: ma, confidence: conf, lastUpdated: now))

  if newEntries.len > 0:
    addressBook.book[peerId] = newEntries
  elif peerId in addressBook.book:
    addressBook.book.del(peerId)

  for handler in addressBook.changeHandlers:
    handler(peerId)

proc `[]=`*(addressBook: AddressBook, peerId: PeerId, addrs: seq[MultiAddress]) =
  addressBook.set(peerId, addrs)

proc `[]`*(addressBook: AddressBook, peerId: PeerId): seq[MultiAddress] =
  ## Return non-expired addresses for `peerId`.
  for entry in addressBook.book.getOrDefault(peerId):
    if not entry.isExpired(addressBook.ttls):
      result.add(entry.address)

proc entries*(addressBook: AddressBook, peerId: PeerId): seq[AddressEntry] =
  ## Return the raw entry list for `peerId`, including expired entries.
  addressBook.book.getOrDefault(peerId)

proc contains*(addressBook: AddressBook, peerId: PeerId): bool =
  for entry in addressBook.book.getOrDefault(peerId):
    if not entry.isExpired(addressBook.ttls):
      return true
  return false

proc markConnected*(addressBook: AddressBook, peerId: PeerId, ma: MultiAddress) =
  ## Called after a successful outbound connection to `ma`.
  ## Upgrades the address to High confidence and refreshes its lastUpdated.
  ## If the address is not yet in the book it is added.
  let now = Moment.now()
  var entries = addressBook.book.getOrDefault(peerId)
  var found = false
  for entry in entries.mitems:
    if entry.address == ma:
      entry.confidence = max(entry.confidence, AddressConfidence.High)
      entry.lastUpdated = now
      found = true
      break
  if not found:
    entries.add(
      AddressEntry(address: ma, confidence: AddressConfidence.High, lastUpdated: now)
    )
  addressBook.book[peerId] = entries
  for handler in addressBook.changeHandlers:
    handler(peerId)

proc extend*(
    addressBook: AddressBook,
    key: PeerId,
    addrs: seq[MultiAddress],
    confidence = AddressConfidence.Medium,
) =
  ## Add addresses for `key` without removing existing ones.
  ## For addresses already present the confidence is upgraded to
  ## `max(existing, confidence)` and lastUpdated is refreshed.
  ## New addresses are added with `confidence`.
  let now = Moment.now()
  var entries = addressBook.book.getOrDefault(key)
  var idxByAddr: Table[MultiAddress, int]
  for i, entry in entries:
    idxByAddr[entry.address] = i
  for ma in addrs:
    if ma in idxByAddr:
      let idx = idxByAddr[ma]
      entries[idx].confidence = max(entries[idx].confidence, confidence)
      entries[idx].lastUpdated = now
    else:
      entries.add(AddressEntry(address: ma, confidence: confidence, lastUpdated: now))
  if entries.len > 0:
    addressBook.book[key] = entries
  for handler in addressBook.changeHandlers:
    handler(key)

proc pruneExpired*(addressBook: AddressBook): seq[PeerId] =
  ## Remove all per-address entries whose TTL has elapsed.
  ## Peers whose last address is pruned are deleted from the book and
  ## returned so the caller can remove them from other books as well.
  var toUpdate: seq[(PeerId, seq[AddressEntry])]
  var toDelete: seq[PeerId]
  for peerId, entries in addressBook.book:
    let alive = entries.filterIt(not it.isExpired(addressBook.ttls))
    if alive.len == 0:
      toDelete.add(peerId)
    elif alive.len < entries.len:
      toUpdate.add((peerId, alive))
  for (peerId, alive) in toUpdate:
    addressBook.book[peerId] = alive
    for handler in addressBook.changeHandlers:
      handler(peerId)
  for peerId in toDelete:
    discard addressBook.del(peerId)
  toDelete

proc addressPruneLoop(
    peerStore: PeerStore, interval: Duration
) {.async: (raises: [CancelledError]).} =
  heartbeat "AddressBook TTL pruning", interval, sleepFirst = true:
    for peerId in peerStore[AddressBook].pruneExpired():
      peerStore.del(peerId)

##################
# Peer Store API #
##################
macro getTypeName(t: type): untyped =
  # Generate unique name in form of Module.Type
  let typ = getTypeImpl(t)[1]
  newLit(repr(typ.owner()) & "." & repr(typ))

proc `[]`*(p: PeerStore, _: type[AddressBook]): AddressBook =
  ## Get the AddressBook, initialising it with the store's configured TTLs.
  let name = getTypeName(AddressBook)
  var book = AddressBook(p.books.getOrDefault(name))
  if book.isNil:
    book = AddressBook.new()
    book.ttls = p.addressTtls
    book.deletor = proc(pid: PeerId) =
      discard AddressBook(p.books.getOrDefault(name)).del(pid)
    p.books[name] = book
  book

proc startAddressPruning*(peerStore: PeerStore) =
  ## Start the periodic per-address TTL pruning loop. No-op if already running.
  ## The loop fires at the Low-confidence TTL interval (shortest possible expiry).
  if not peerStore.pruneHandle.isNil:
    return
  peerStore.pruneHandle = addressPruneLoop(peerStore, peerStore.addressTtls.low)

proc close*(peerStore: PeerStore) =
  ## Cancel the background TTL-pruning loop, if running.
  if not peerStore.pruneHandle.isNil:
    peerStore.pruneHandle.cancelSoon()
    peerStore.pruneHandle = nil

proc `[]`*[T](p: PeerStore, typ: type[T]): T =
  ## Get a book from the PeerStore (ex: peerStore[AddressBook])
  let name = getTypeName(T)
  var book = T(p.books.getOrDefault(name))
  if book.isNil:
    book = T.new()
    book.deletor = proc(pid: PeerId) =
      # Manual method because generic method
      # don't work
      discard T(p.books.getOrDefault(name)).del(pid)
    p.books[name] = book
  book

proc del*(peerStore: PeerStore, peerId: PeerId) =
  ## Delete the provided peer from every book.
  for _, book in peerStore.books:
    book.deletor(peerId)

proc updatePeerInfo*(
    peerStore: PeerStore,
    info: IdentifyInfo,
    observedAddr: Opt[MultiAddress] = Opt.none(MultiAddress),
    direction: Opt[Direction] = Opt.none(Direction),
) =
  if len(info.addrs) > 0:
    let addrs = peerStore.addressPolicy.filterAddrs(info.addrs)
    if addrs.len > 0:
      peerStore[AddressBook].set(info.peerId, addrs, AddressConfidence.Medium)
    else:
      discard peerStore[AddressBook].del(info.peerId)

  peerStore[LastSeenBook][info.peerId] = observedAddr

  # Update LastSeenOutboundBook only for outbound connections
  direction.withValue(dir):
    if dir == Direction.Out:
      peerStore[LastSeenOutboundBook][info.peerId] = observedAddr

  info.pubkey.withValue(pubkey):
    peerStore[KeyBook][info.peerId] = pubkey

  info.agentVersion.withValue(agentVersion):
    peerStore[AgentBook][info.peerId] = agentVersion

  info.protoVersion.withValue(protoVersion):
    peerStore[ProtoVersionBook][info.peerId] = protoVersion

  if info.protos.len > 0:
    peerStore[ProtoBook][info.peerId] = info.protos

  info.signedPeerRecord.withValue(signedPeerRecord):
    peerStore[SPRBook][info.peerId] = signedPeerRecord

  let cleanupPos = peerStore.toClean.find(info.peerId)
  if cleanupPos >= 0:
    peerStore.toClean.delete(cleanupPos)

proc cleanup*(peerStore: PeerStore, peerId: PeerId) =
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
    peerStore: PeerStore, muxer: Muxer, dir: Direction
) {.
    async: (
      raises: [
        CancelledError, IdentityNoMatchError, IdentityInvalidMsgError, MultiStreamError,
        LPStreamError, MuxerError,
      ]
    )
.} =
  # new stream for identify
  var stream = await muxer.newStream()
  if stream == nil:
    return

  try:
    if (await MultistreamSelect.select(stream, peerStore.identify.codec())):
      let info = await peerStore.identify.identify(stream, stream.peerId)

      when defined(libp2p_agents_metrics):
        var
          knownAgent = "unknown"
          shortAgent =
            info.agentVersion.get("").split("/")[0].safeToLowerAscii().get("")
        if KnownLibP2PAgentsSeq.contains(shortAgent):
          knownAgent = shortAgent
        muxer.setShortAgent(knownAgent)

      peerStore.updatePeerInfo(info, stream.observedAddr, Opt.some(dir))
  finally:
    await stream.closeWithEOF()

proc getMostObservedProtosAndPorts*(self: PeerStore): seq[MultiAddress] =
  return self.identify.observedAddrManager.getMostObservedProtosAndPorts()

proc guessDialableAddr*(self: PeerStore, ma: MultiAddress): MultiAddress =
  return self.identify.observedAddrManager.guessDialableAddr(ma)

proc extend*[T](self: SeqPeerBook[T], key: PeerId, new: seq[T]) =
  var extended: HashSet[T]

  for old in self[key]:
    extended.incl(old)

  for elem in new:
    extended.incl(elem)

  self[key] = extended.toSeq()

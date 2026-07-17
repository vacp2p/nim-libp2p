# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sets, tables]
import chronos, results
import ../../[peerid, multiaddress, routing_record]
import ../../utils/iptree
import ./types

export types

proc getIPs(addrsInfos: seq[AddressInfo]): seq[IpAddress] =
  var ips: seq[IpAddress]
  for addrInfo in addrsInfos:
    addrInfo.address.getIp().withValue(ip):
      ips.add(ip)
  ips

proc insertAd(ipTree: IpTree, ad: Advertisement) =
  for ip in ad.data.addresses.getIPs():
    ipTree.insertIp(ip)

proc removeAd(ipTree: IpTree, ad: Advertisement) =
  for ip in ad.data.addresses.getIPs():
    ipTree.removeIp(ip)

proc adScore(ipTree: IpTree, ad: Advertisement): float64 =
  ## Max IP similarity score across the advertisement's addresses.
  var maxScore = 0.0
  for ip in ad.data.addresses.getIPs():
    let score = ipTree.ipScore(ip)
    if score > maxScore:
      maxScore = score
  maxScore

proc len*(c: AdvertisementCache): int =
  ## Number of unique advertisements (capacity accounting unit).
  c.entries.len

proc serviceCount*(c: AdvertisementCache): int =
  c.byService.len

proc serviceAdCount*(c: AdvertisementCache, serviceId: ServiceId): int =
  c.byService.withValue(serviceId, peers):
    return peers[].len
  0

proc contains*(c: AdvertisementCache, key: AdvertisementKey): bool =
  key in c.entries

proc containsService*(c: AdvertisementCache, serviceId: ServiceId): bool =
  serviceId in c.byService

proc adsForService*(c: AdvertisementCache, serviceId: ServiceId): seq[Advertisement] =
  result = @[]
  c.byService.withValue(serviceId, peers):
    for _, key in peers[]:
      c.entries.withValue(key, entry):
        result.add(entry[].ad)

proc timestamp*(c: AdvertisementCache, key: AdvertisementKey): Opt[Moment] =
  c.entries.withValue(key, entry):
    return Opt.some(entry[].timestamp)
  Opt.none(Moment)

proc adScore*(c: AdvertisementCache, ad: Advertisement): float64 =
  c.ipTree.adScore(ad)

proc ipTotal*(c: AdvertisementCache): int =
  ## Total IP multi-set size (IPv4 + IPv6 root counters).
  c.ipTree.root.counter + c.ipTree.root6.counter

proc ipScore*(c: AdvertisementCache, ip: IpAddress): float64 =
  c.ipTree.ipScore(ip)

proc dropServicePeer(c: AdvertisementCache, serviceId: ServiceId, peerId: PeerId) =
  c.byService.withValue(serviceId, peers):
    peers[].del(peerId)
    if peers[].len == 0:
      c.byService.del(serviceId)

proc setServicePeer(
    c: AdvertisementCache, serviceId: ServiceId, peerId: PeerId, key: AdvertisementKey
) =
  if serviceId notin c.byService:
    c.byService[serviceId] = initTable[PeerId, AdvertisementKey]()
  c.byService.withValue(serviceId, peers):
    peers[][peerId] = key

proc remove*(c: AdvertisementCache, key: AdvertisementKey): bool =
  ## Remove `key` from every service and free the IP tree once per membership.
  ## Idempotent: returns false if the key was not present.
  var entry: CachedAd
  c.entries.withValue(key, e):
    entry = e[]
  do:
    return false

  let peerId = entry.ad.data.peerId
  for serviceId in entry.services:
    c.ipTree.removeAd(entry.ad)
    c.dropServicePeer(serviceId, peerId)
  c.entries.del(key)
  true

proc evictOldest(c: AdvertisementCache) =
  var oldestKey: AdvertisementKey
  var oldestTime = Moment.high
  for k, e in c.entries:
    if e.timestamp < oldestTime:
      oldestTime = e.timestamp
      oldestKey = k
  if oldestTime != Moment.high:
    discard c.remove(oldestKey)

proc replaceEverywhere(
    c: AdvertisementCache, oldKey: AdvertisementKey, ad: Advertisement, now: Moment
) =
  var oldEntry: CachedAd
  c.entries.withValue(oldKey, e):
    oldEntry = e[]
  do:
    return

  let peerId = ad.data.peerId
  let newKey = ad.toAdvertisementKey()
  let oldServices = oldEntry.services

  var keptServices = initHashSet[ServiceId]()
  for serviceId in oldServices:
    # Free the old admission's IP contribution for every prior membership.
    c.ipTree.removeAd(oldEntry.ad)
    if ad.advertisesService(serviceId):
      keptServices.incl(serviceId)
    else:
      c.dropServicePeer(serviceId, peerId)

  c.entries.del(oldKey)

  if keptServices.len == 0:
    return

  if newKey in c.entries:
    c.entries.withValue(newKey, newEntry):
      newEntry[].ad = ad
      newEntry[].timestamp = now
      for serviceId in keptServices:
        newEntry[].services.incl(serviceId)
        c.setServicePeer(serviceId, peerId, newKey)
        c.ipTree.insertAd(ad)
  else:
    c.entries[newKey] = CachedAd(ad: ad, timestamp: now, services: keptServices)
    for serviceId in keptServices:
      c.setServicePeer(serviceId, peerId, newKey)
      c.ipTree.insertAd(ad)

proc put*(
    c: AdvertisementCache,
    serviceId: ServiceId,
    ad: Advertisement,
    now: Moment,
    capacity: uint64,
): AdPutResult =
  ## Admit or update `ad` for `serviceId`.

  doAssert capacity > 0, "capacity must be > 0"

  let peerId = ad.data.peerId
  let key = ad.toAdvertisementKey()

  var existingKey: AdvertisementKey
  var hasPeer = false
  c.byService.withValue(serviceId, peers):
    peers[].withValue(peerId, oldKeyPtr):
      existingKey = oldKeyPtr[]
      hasPeer = true

  if hasPeer:
    var oldEntry: CachedAd
    c.entries.withValue(existingKey, e):
      oldEntry = e[]
    do:
      # Index without primary row should not happen; treat as new admission.
      hasPeer = false

    if hasPeer:
      if ad.data.seqNo == oldEntry.ad.data.seqNo:
        oldEntry.timestamp = now
        return AdRefreshed
      elif ad.data.seqNo < oldEntry.ad.data.seqNo:
        return AdIgnored
      else:
        c.replaceEverywhere(existingKey, ad, now)
        return AdReplaced

  # New (service, peer) admission.
  if key notin c.entries and c.entries.len.uint64 >= capacity:
    c.evictOldest()

  if key in c.entries:
    c.entries.withValue(key, entry):
      entry[].services.incl(serviceId)
      entry[].timestamp = now
      entry[].ad = ad
  else:
    var services = initHashSet[ServiceId]()
    services.incl(serviceId)
    c.entries[key] = CachedAd(ad: ad, timestamp: now, services: services)

  c.setServicePeer(serviceId, peerId, key)
  c.ipTree.insertAd(ad)
  AdInserted

proc pruneExpired*(c: AdvertisementCache, now: Moment, expiry: Duration): int =
  ## Remove entries whose timestamp is older than `expiry`. Returns how many
  ## unique ads were removed.
  var toRemove: seq[AdvertisementKey]
  for k, e in c.entries:
    if now - e.timestamp > expiry:
      toRemove.add(k)

  for k in toRemove:
    discard c.remove(k)
  toRemove.len

proc clear*(c: AdvertisementCache) =
  c.entries.clear()
  c.byService.clear()
  c.ipTree = IpTree.new()

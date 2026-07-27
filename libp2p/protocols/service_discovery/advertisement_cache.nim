# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, tables]
import chronos, results
import ../../[peerid, multiaddress]
import ../../utils/iptree
import ./types

export types

proc insertIps(ipTree: IpTree, ips: seq[IpAddress]) =
  for ip in ips:
    ipTree.insertIp(ip)

proc removeIps(ipTree: IpTree, ips: seq[IpAddress]) =
  for ip in ips:
    ipTree.removeIp(ip)

proc ipMaxScore(ipTree: IpTree, ips: seq[IpAddress]): float64 =
  ## Max IP similarity score across the given addresses.
  var maxScore = 0.0
  for ip in ips:
    let score = ipTree.ipScore(ip)
    if score > maxScore:
      maxScore = score
  maxScore

proc len*(c: AdvertisementCache): int =
  c.count

proc serviceCount*(c: AdvertisementCache): int =
  c.byService.len

proc serviceAdCount*(c: AdvertisementCache, serviceId: ServiceId): int =
  c.byService.withValue(serviceId, peers):
    return peers[].len
  0

proc containsService*(c: AdvertisementCache, serviceId: ServiceId): bool =
  serviceId in c.byService

proc contains*(c: AdvertisementCache, serviceId: ServiceId, advertiser: PeerId): bool =
  ## True when `advertiser` already has a cached ad under `serviceId`.
  c.byService.withValue(serviceId, peers):
    return advertiser in peers[]
  false

proc adsForService*(c: AdvertisementCache, serviceId: ServiceId): seq[Advertisement] =
  var ads: seq[Advertisement] = @[]
  c.byService.withValue(serviceId, peers):
    for _, slot in peers[]:
      ads.add(slot.ad)
  ads

proc getCachedAd*(
    c: AdvertisementCache, serviceId: ServiceId, advertiser: PeerId
): Opt[CachedAd] =
  c.byService.withValue(serviceId, peers):
    peers[].withValue(advertiser, slot):
      return Opt.some(slot[])
  Opt.none(CachedAd)

proc ipMaxScore*(c: AdvertisementCache, ips: seq[IpAddress]): float64 =
  c.ipTree.ipMaxScore(ips)

proc ipTotal*(c: AdvertisementCache): int =
  ## Total IP multi-set size (IPv4 + IPv6 root counters).
  c.ipTree.root.counter + c.ipTree.root6.counter

proc ipScore*(c: AdvertisementCache, ip: IpAddress): float64 =
  c.ipTree.ipScore(ip)

proc removeSlot(c: AdvertisementCache, serviceId: ServiceId, advertiser: PeerId) =
  c.byService.withValue(serviceId, peers):
    peers[].withValue(advertiser, slot):
      c.ipTree.removeIps(slot[].ips)
      peers[].del(advertiser)
      dec c.count
    if peers[].len == 0:
      c.byService.del(serviceId)

proc findOldestEntry(c: AdvertisementCache): Opt[(ServiceId, PeerId)] =
  var oldest = Opt.none((ServiceId, PeerId))
  var oldestTime = Moment.high

  for serviceId, peers in c.byService:
    for advertiser, slot in peers:
      if slot.timestamp <= oldestTime:
        oldestTime = slot.timestamp
        oldest = Opt.some((serviceId, advertiser))

  oldest

proc evictOldest(c: AdvertisementCache) =
  c.findOldestEntry().withValue(entry):
    c.removeSlot(entry[0], entry[1])

proc put*(
    c: AdvertisementCache,
    serviceId: ServiceId,
    advertiser: PeerId,
    ad: Advertisement,
    ips: seq[IpAddress],
    now: Moment,
) =
  ## Insert or replace the ad for `(serviceId, advertiser)`.
  ## Replace updates payload, IPs, and timestamp without consuming capacity.
  ## New inserts evict the oldest slot when the cache is full.
  c.byService.withValue(serviceId, peers):
    if advertiser in peers[]:
      peers[].withValue(advertiser, slot):
        c.ipTree.removeIps(slot[].ips)
        slot[] = CachedAd(ad: ad, advertiser: advertiser, ips: ips, timestamp: now)
        c.ipTree.insertIps(ips)
      return

  if c.count.uint64 >= c.capacity:
    c.evictOldest()

  if serviceId notin c.byService:
    c.byService[serviceId] = initTable[PeerId, CachedAd]()
  c.byService.withValue(serviceId, peers):
    peers[][advertiser] =
      CachedAd(ad: ad, advertiser: advertiser, ips: ips, timestamp: now)
  c.ipTree.insertIps(ips)
  inc c.count

proc pruneExpired*(c: AdvertisementCache, now: Moment, expiry: Duration): int =
  ## Remove slots whose timestamp is older than `expiry`. Returns how many
  ## slots were removed.
  let cutoff = now - expiry
  var
    removed = 0
    emptyServices: seq[ServiceId]
    toRemove: seq[(ServiceId, PeerId)]

  for serviceId, peers in c.byService:
    for advertiser, slot in peers:
      if slot.timestamp < cutoff:
        toRemove.add((serviceId, advertiser))

  for (serviceId, advertiser) in toRemove:
    c.removeSlot(serviceId, advertiser)
    inc removed

  for serviceId, peers in c.byService:
    if peers.len == 0:
      emptyServices.add(serviceId)

  for serviceId in emptyServices:
    c.byService.del(serviceId)

  removed

proc clear*(c: AdvertisementCache) =
  c.byService.clear()
  c.ipTree = IpTree.new()
  c.count = 0

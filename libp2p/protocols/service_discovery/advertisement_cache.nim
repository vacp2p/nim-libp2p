# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[net, tables]
import chronos, results
import ../../peerid
import ../../utils/iptree
import ./types

export types

proc len*(c: AdvertisementCache): int =
  c.count

proc serviceLen*(c: AdvertisementCache): int =
  c.byService.len

proc serviceCacheAdsLen*(c: AdvertisementCache, serviceId: ServiceId): int =
  c.byService.withValue(serviceId, peers):
    return peers[].len
  0

proc contains*(c: AdvertisementCache, serviceId: ServiceId): bool =
  serviceId in c.byService

proc contains*(c: AdvertisementCache, serviceId: ServiceId, advertiser: PeerId): bool =
  c.byService.withValue(serviceId, peers):
    return advertiser in peers[]
  false

proc getServiceCachedAds*(
    c: AdvertisementCache, serviceId: ServiceId, limit: int
): seq[CachedAd] =
  if limit <= 0:
    return @[]
  var ads: seq[CachedAd]
  c.byService.withValue(serviceId, peers):
    ads = newSeqOfCap[CachedAd](min(limit, peers[].len))
    for _, cachedAd in peers[]:
      if ads.len >= limit:
        break
      ads.add(cachedAd)
  ads

proc getCachedAd*(
    c: AdvertisementCache, serviceId: ServiceId, advertiser: PeerId
): Opt[CachedAd] =
  c.byService.withValue(serviceId, peers):
    peers[].withValue(advertiser, cachedAd):
      return Opt.some(cachedAd[])
  Opt.none(CachedAd)

proc remove(c: AdvertisementCache, serviceId: ServiceId, advertiser: PeerId) =
  c.byService.withValue(serviceId, peers):
    peers[].withValue(advertiser, cachedAd):
      c.ipTree.removeIps(cachedAd[].ips)
      peers[].del(advertiser)
      dec c.count
    if peers[].len == 0:
      c.byService.del(serviceId)

proc findOldest(c: AdvertisementCache): Opt[(ServiceId, PeerId)] =
  var oldest = Opt.none((ServiceId, PeerId))
  var oldestTime = Moment.high

  for serviceId, peers in c.byService:
    for advertiser, cachedAd in peers:
      if cachedAd.timestamp <= oldestTime:
        oldestTime = cachedAd.timestamp
        oldest = Opt.some((serviceId, advertiser))

  oldest

proc evictOldest(c: AdvertisementCache) =
  c.findOldest().withValue(entry):
    c.remove(entry[0], entry[1])

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
  ## New inserts evict the oldest cachedAd when the cache is full.
  c.byService.withValue(serviceId, peers):
    if advertiser in peers[]:
      peers[].withValue(advertiser, cachedAd):
        c.ipTree.removeIps(cachedAd[].ips)
        cachedAd[] = CachedAd(ad: ad, advertiser: advertiser, ips: ips, timestamp: now)
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
  ## Remove cachedAds whose timestamp is older than `expiry`. Returns how many
  ## cachedAds were removed.
  let cutoff = now - expiry
  var
    removed = 0
    toRemove: seq[(ServiceId, PeerId)]

  for serviceId, peers in c.byService:
    for advertiser, cachedAd in peers:
      if cachedAd.timestamp < cutoff:
        toRemove.add((serviceId, advertiser))

  for (serviceId, advertiser) in toRemove:
    c.remove(serviceId, advertiser)
    inc removed

  removed

proc clear*(c: AdvertisementCache) =
  c.byService.clear()
  c.ipTree = IpTree.new()
  c.count = 0

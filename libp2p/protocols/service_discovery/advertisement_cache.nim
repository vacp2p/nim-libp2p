# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, tables]
import chronos, results
import ../../[multiaddress, routing_record]
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
  var n = 0
  for _, slots in c.byService:
    n += slots.len
  n

proc serviceCount*(c: AdvertisementCache): int =
  c.byService.len

proc serviceAdCount*(c: AdvertisementCache, serviceId: ServiceId): int =
  c.byService.withValue(serviceId, slots):
    return slots[].len
  0

proc containsService*(c: AdvertisementCache, serviceId: ServiceId): bool =
  serviceId in c.byService

proc contains*(c: AdvertisementCache, serviceId: ServiceId, ad: Advertisement): bool =
  ## True when an identical ad (same envelope signature) is already cached
  ## under `serviceId`.
  c.byService.withValue(serviceId, slots):
    for slot in slots[]:
      if slot.ad.envelope.signature.data == ad.envelope.signature.data:
        return true
  false

proc adsForService*(c: AdvertisementCache, serviceId: ServiceId): seq[Advertisement] =
  result = @[]
  c.byService.withValue(serviceId, slots):
    for slot in slots[]:
      result.add(slot.ad)

proc adScore*(c: AdvertisementCache, ad: Advertisement): float64 =
  c.ipTree.adScore(ad)

proc ipTotal*(c: AdvertisementCache): int =
  ## Total IP multi-set size (IPv4 + IPv6 root counters).
  c.ipTree.root.counter + c.ipTree.root6.counter

proc ipScore*(c: AdvertisementCache, ip: IpAddress): float64 =
  c.ipTree.ipScore(ip)

proc removeSlot(c: AdvertisementCache, serviceId: ServiceId, index: int) =
  c.byService.withValue(serviceId, slots):
    if index < 0 or index >= slots[].len:
      return
    c.ipTree.removeAd(slots[][index].ad)
    slots[].del(index)
    if slots[].len == 0:
      c.byService.del(serviceId)

proc evictOldest(c: AdvertisementCache) =
  var oldestService: ServiceId
  var oldestIndex = -1
  var oldestTime = Moment.high

  for serviceId, slots in c.byService:
    for i, slot in slots:
      if slot.timestamp < oldestTime:
        oldestTime = slot.timestamp
        oldestService = serviceId
        oldestIndex = i

  if oldestIndex >= 0:
    c.removeSlot(oldestService, oldestIndex)

proc put*(c: AdvertisementCache, serviceId: ServiceId, ad: Advertisement, now: Moment) =
  ## Append a new ad slot for `serviceId`. Evicts the oldest slot when full.
  ## Callers must reject duplicates via `contains` before calling `put`.
  if c.len.uint64 >= c.capacity:
    c.evictOldest()

  if serviceId notin c.byService:
    c.byService[serviceId] = @[]
  c.byService.withValue(serviceId, slots):
    slots[].add(CachedAd(ad: ad, timestamp: now))
  c.ipTree.insertAd(ad)

proc pruneExpired*(c: AdvertisementCache, now: Moment, expiry: Duration): int =
  ## Remove slots whose timestamp is older than `expiry`. Returns how many
  ## slots were removed.
  var removed = 0
  var emptyServices: seq[ServiceId]

  for serviceId, slots in c.byService.mpairs:
    var kept: seq[CachedAd]
    for slot in slots:
      if now - slot.timestamp > expiry:
        c.ipTree.removeAd(slot.ad)
        inc removed
      else:
        kept.add(slot)
    slots = kept
    if slots.len == 0:
      emptyServices.add(serviceId)

  for serviceId in emptyServices:
    c.byService.del(serviceId)

  removed

proc clear*(c: AdvertisementCache) =
  c.byService.clear()
  c.ipTree = IpTree.new()

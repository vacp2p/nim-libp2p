# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sets, strutils]
import chronos, chronicles, results, stew/byteutils
import ../../peerid
import ./[types, service_discovery_metrics]

logScope:
  topics = "service-disco tracker"

const MaxTrackedProviders* = 1024

proc new*(
    T: typedesc[DiscoveryTracker], selfId: PeerId, maxProviders = MaxTrackedProviders
): T {.raises: [].} =
  T(
    selfId: selfId,
    maxProviders: maxProviders,
    interests: initTable[ServiceId, ServiceInterest](),
  )

proc startInterest*(tracker: DiscoveryTracker, serviceId: ServiceId) {.raises: [].} =
  ## A running interest keeps its start time, so a repeated lookup does not reset it.
  tracker.interests.withValue(serviceId, interest):
    if interest[].active:
      return

  tracker.interests[serviceId] = ServiceInterest(
    active: true,
    startedAt: Moment.now(),
    seen: initHashSet[PeerId](),
    found: newSeq[ProviderDiscovery](),
  )

proc stopInterest*(tracker: DiscoveryTracker, serviceId: ServiceId) {.raises: [].} =
  tracker.interests.withValue(serviceId, interest):
    interest[].active = false

proc recordProvider*(
    tracker: DiscoveryTracker,
    serviceId: ServiceId,
    provider: PeerId,
    source: DiscoverySource,
) {.raises: [].} =
  ## Records the first sight of `provider`, timed from the start of the interest.
  if provider == tracker.selfId:
    return

  tracker.interests.withValue(serviceId, interest):
    if not interest[].active:
      return
    if interest[].found.len >= tracker.maxProviders:
      return
    if interest[].seen.containsOrIncl(provider):
      return

    let elapsed = Moment.now() - interest[].startedAt
    let discovery = ProviderDiscovery(
      provider: provider,
      rank: interest[].found.len + 1,
      elapsed: elapsed,
      source: source,
    )
    interest[].found.add(discovery)

    let elapsedSeconds = elapsed.nanoseconds.float64 / 1_000_000_000.0
    cd_provider_discovery_seconds.observe(elapsedSeconds)
    if discovery.rank == 1:
      cd_first_provider_discovery_seconds.observe(elapsedSeconds)

    debug "Provider found",
      serviceId,
      provider,
      rank = discovery.rank,
      elapsedMs = elapsed.milliseconds,
      source

proc recordProviders*(
    tracker: DiscoveryTracker,
    serviceId: ServiceId,
    ads: seq[Advertisement],
    source: DiscoverySource,
) {.raises: [].} =
  for ad in ads:
    tracker.recordProvider(serviceId, ad.data.peerId, source)

func discoveries*(
    tracker: DiscoveryTracker, serviceId: ServiceId
): seq[ProviderDiscovery] {.raises: [].} =
  ## Raw per-provider timings for one service, in discovery order.
  tracker.interests.getOrDefault(serviceId).found

func startedAt*(
    tracker: DiscoveryTracker, serviceId: ServiceId
): Opt[Moment] {.raises: [].} =
  tracker.interests.withValue(serviceId, interest):
    return Opt.some(interest[].startedAt)
  Opt.none(Moment)

proc clear*(tracker: DiscoveryTracker) {.raises: [].} =
  tracker.interests.clear()

proc toCsv*(tracker: DiscoveryTracker): string {.raises: [].} =
  ## Raw data dump: one row per discovered provider.
  var rows = @["service_id,provider,rank,elapsed_ms,source"]
  for serviceId, interest in tracker.interests:
    let service = serviceId.toHex()
    for d in interest.found:
      rows.add(
        service & "," & $d.provider & "," & $d.rank & "," & $d.elapsed.milliseconds & "," &
          $d.source
      )
  rows.join("\n")

func discoveries*(
    disco: ServiceDiscovery, service: string
): seq[ProviderDiscovery] {.raises: [].} =
  disco.tracker.discoveries(service.hashServiceId())

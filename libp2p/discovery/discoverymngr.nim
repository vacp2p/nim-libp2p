# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
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

import sequtils
import chronos, chronicles
import ./discoveryinterface,
       ../errors

export discoveryinterface

type
  DiscoveryError* = object of LPError
  DiscoveryManager* = ref object
    interfaces: seq[DiscoveryInterface]
    queries: seq[DiscoveryQuery]

  DiscoveryQuery* = ref object
    filter: DiscoveryFilters
    peers: AsyncQueue[DiscoveryFilters]
    futs: seq[Future[void]]

proc add*(dm: DiscoveryManager, di: DiscoveryInterface) =
  dm.interfaces &= di

  di.onPeerFound = proc (res: DiscoveryFilters) =
    for query in dm.queries:
      if query.filter.match(res):
        try:
          query.peers.putNoWait(res)
        except AsyncQueueFullError as exc:
          debug "Cannot push discovered peer to queue"

proc request*(dm: DiscoveryManager, filter: DiscoveryFilters): DiscoveryQuery =
  var query = DiscoveryQuery(filter: filter, peers: newAsyncQueue[DiscoveryFilters]())
  for i in dm.interfaces:
    query.futs.add(i.request(filter))
  return query

proc advertise*(dm: DiscoveryManager, filter: DiscoveryFilters) {.async.} =
  for i in dm.interfaces:
    i.toAdvertise = filter
    if i.advertiseLoop.isNil:
      i.advertisementUpdated = newAsyncEvent()
      i.advertiseLoop = i.advertise()
    else:
      i.advertisementUpdated.fire()

proc stop*(dm: DiscoveryManager) =
  for i in dm.interfaces:
    if isNil(i.advertiseLoop): continue
    i.advertiseLoop.cancel()

proc getPeer*(query: DiscoveryQuery): Future[DiscoveryFilters] {.async.} =
  let getter = query.peers.popFirst()

  try:
    await getter or allFinished(query.futs)
  except CancelledError as exc:
    getter.cancel()
    raise exc

  if not finished(getter):
    raise newException(DiscoveryError, "Unable to find any peer matching this request")
  return await getter

proc stop*(query: DiscoveryQuery) =
  for r in query.futs:
    if not r.finished(): r.cancel()

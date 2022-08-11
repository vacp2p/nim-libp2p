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
import ./discoveryinterface

export discoveryinterface

type
  DiscoveryManager = object
    di: seq[DiscoveryInterface]
    rq: seq[Future[void]]

  DiscoveryQuery = object
    dm: DiscoveryManager
    filter: DiscoveryFilter
    peers: seq[DiscoveryResult]
    foundEvent: AsyncEvent

proc request(dm: var DiscoveryManager, filter: DiscoveryFilter): DiscoveryQuery =
  var query = DiscoveryQuery(dm: dm, filter: filter, foundEvent: newAsyncEvent())
  for i in dm.di:
    i.onPeerFound =
      proc(res: DiscoveryResult) =
        query.peers.add(res)
        query.foundEvent.fire()
    dm.rq.add(i.request(filter))

proc advertise(dm: DiscoveryManager, filter: DiscoveryFilter) {.async.} =
  for i in dm.di:
    i.advertise(filter)

proc getPeer(query: var DiscoveryQuery): Future[DiscoveryResult] {.async.} =
  if query.dm.rq.allIt(it.finished()) and query.peers.len == 0:
    query = query.dm.request(query.filter)
  if query.peers.len > 0:
    result = query.peers[0]
    query.peers.delete(0)
    return
  query.foundEvent.clear()
  await query.foundEvent.wait()
  if query.peers.len > 0:
    result = query.peers[0]
    query.peers.delete(0)

proc stop(query: DiscoveryQuery) =
  for r in query.dm.rq: r.cancel()

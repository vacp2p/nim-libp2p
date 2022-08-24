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
  DiscoveryManager* = ref object of RootObj
    di: seq[DiscoveryInterface]
    rq: seq[Future[void]]

  DiscoveryQuery* = ref object of RootObj
    dm: DiscoveryManager
    filter: DiscoveryFilter
    peers: seq[DiscoveryResult]
    foundEvent: AsyncEvent

method add*(dm: DiscoveryManager, di: DiscoveryInterface) =
  dm.di &= di

method request*(dm: DiscoveryManager, filter: DiscoveryFilter): DiscoveryQuery {.base.} =
  var query = DiscoveryQuery(dm: dm, filter: filter, foundEvent: newAsyncEvent())
  for i in dm.di:
    i.onPeerFound =
      proc(res: DiscoveryResult) {.raises: [Defect], gcsafe.} =
        query.peers.add(res)
        query.foundEvent.fire()
    dm.rq.add(i.request(filter))
  return query

method advertise*(dm: DiscoveryManager, filter: DiscoveryFilter) {.async, base.} =
  for i in dm.di:
    await i.advertise(filter)

method getPeer*(query: DiscoveryQuery): Future[DiscoveryResult] {.async, base.} =
  if query.dm.rq.allIt(it.finished()) and query.peers.len == 0:
    discard # TODO: raise ntm
  if query.peers.len > 0:
    result = query.peers[0]
    query.peers.delete(0)
    return
  query.foundEvent.clear()
  await query.foundEvent.wait()
  if query.peers.len > 0:
    result = query.peers[0]
    query.peers.delete(0)

proc stop*(query: DiscoveryQuery) =
  for r in query.dm.rq:
    if not r.finished(): r.cancel()
  for i in query.dm.di:
    i.onPeerFound = nil

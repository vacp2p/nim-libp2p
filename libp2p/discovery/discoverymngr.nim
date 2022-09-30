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

import chronos, chronicles
import ./discoveryinterface,
       ../errors

export discoveryinterface

type
  BaseAttr = ref object of RootObj
    comparator*: proc(f: BaseAttr, c: BaseAttr): bool {.gcsafe, raises: [Defect].}

  Attribute[T] = ref object of BaseAttr
    value*: T

  PeerAttributes* = object
    attributes: seq[BaseAttr]

  DiscoveryService* = distinct string

proc `==`*(a, b: DiscoveryService): bool {.borrow.}

proc ofType*[T](f: BaseAttr, _: type[T]): bool =
  return f is Attribute[T]

proc to*[T](f: BaseAttr, _: type[T]): T =
  Attribute[T](f).value

proc add*[T](pa: var PeerAttributes,
             value: T) =
  pa.attributes.add(Attribute[T](
      value: value,
      comparator: proc(f: BaseAttr, c: BaseAttr): bool =
        f.ofType(T) and c.ofType(T) and f.to(T).value == c.to(T).value
    )
  )

iterator items*(pa: PeerAttributes): BaseAttr =
  for f in pa.attributes:
    yield f

proc `[]`*[T](pa: PeerAttributes, t: typedesc[T]): seq[T] =
  for f in pa.attributes:
    if f.ofType(T)
      result.add(f.to(T).value)

proc match*(pa, candidate: PeerAttributes): bool =
  for f in pa.attributes:
    block oneAttribute:
      for field in candidate.attributes:
        if field.comparator(field, f):
          break oneAttribute
      return false
  return true

type
  PeerFoundCallback* = proc(pa: PeerAttributes) {.raises: [Defect], gcsafe.}

  DiscoveryInterface* = ref object of RootObj
    onPeerFound*: PeerFoundCallback
    toAdvertise*: PeerAttributes
    advertisementUpdated*: AsyncEvent
    advertiseLoop*: Future[void]

method request*(self: DiscoveryInterface, pa: PeerAttributes) {.async, base.} =
  doAssert(false, "Not implemented!")

method advertise*(self: DiscoveryInterface) {.async, base.} =
  doAssert(false, "Not implemented!")

type
  DiscoveryError* = object of LPError

  DiscoveryQuery* = ref object
    attr: PeerAttributes
    peers: AsyncQueue[PeerAttributes]
    futs: seq[Future[void]]

  DiscoveryManager* = ref object
    interfaces: seq[DiscoveryInterface]
    queries: seq[DiscoveryQuery]

proc add*(dm: DiscoveryManager, di: DiscoveryInterface) =
  dm.interfaces &= di

  di.onPeerFound = proc (pa: PeerAttributes) =
    for query in dm.queries:
      if query.attr.match(pa):
        try:
          query.peers.putNoWait(pa)
        except AsyncQueueFullError as exc:
          debug "Cannot push discovered peer to queue"

proc request*(dm: DiscoveryManager, pa: PeerAttributes): DiscoveryQuery =
  var query = DiscoveryQuery(attr: pa, peers: newAsyncQueue[PeerAttributes]())
  for i in dm.interfaces:
    query.futs.add(i.request(pa))
  return query

proc advertise*(dm: DiscoveryManager, pa: PeerAttributes) {.async.} =
  for i in dm.interfaces:
    i.toAdvertise = pa
    if i.advertiseLoop.isNil:
      i.advertisementUpdated = newAsyncEvent()
      i.advertiseLoop = i.advertise()
    else:
      i.advertisementUpdated.fire()

proc stop*(dm: DiscoveryManager) =
  for i in dm.interfaces:
    if isNil(i.advertiseLoop): continue
    i.advertiseLoop.cancel()

proc getPeer*(query: DiscoveryQuery): Future[PeerAttributes] {.async.} =
  let getter = query.peers.popFirst()

  try:
    await getter or allFinished(query.futs)
  except CancelledError as exc:
    getter.cancel()
    raise exc

  if not finished(getter):
    # discovery loops only finish when they don't handle the query
    raise newException(DiscoveryError, "Unable to find any peer matching this request")
  return await getter

proc stop*(query: DiscoveryQuery) =
  for r in query.futs:
    if not r.finished(): r.cancel()

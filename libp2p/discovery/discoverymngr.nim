# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/sequtils
import chronos, chronicles, stew/results
import ../errors

type
  BaseAttr = ref object of RootObj
    comparator: proc(f, c: BaseAttr): bool {.gcsafe, raises: [].}

  Attribute[T] = ref object of BaseAttr
    value: T

  PeerAttributes* = object
    attributes: seq[BaseAttr]

  DiscoveryService* = distinct string

proc `==`*(a, b: DiscoveryService): bool {.borrow.}

proc ofType*[T](f: BaseAttr, _: type[T]): bool =
  return f of Attribute[T]

proc to*[T](f: BaseAttr, _: type[T]): T =
  Attribute[T](f).value

proc add*[T](pa: var PeerAttributes, value: T) =
  pa.attributes.add(
    Attribute[T](
      value: value,
      comparator: proc(f: BaseAttr, c: BaseAttr): bool =
        f.ofType(T) and c.ofType(T) and f.to(T) == c.to(T),
    )
  )

iterator items*(pa: PeerAttributes): BaseAttr =
  for f in pa.attributes:
    yield f

proc getAll*[T](pa: PeerAttributes, t: typedesc[T]): seq[T] =
  for f in pa.attributes:
    if f.ofType(T):
      result.add(f.to(T))

proc `{}`*[T](pa: PeerAttributes, t: typedesc[T]): Opt[T] =
  for f in pa.attributes:
    if f.ofType(T):
      return Opt.some(f.to(T))
  Opt.none(T)

proc `[]`*[T](pa: PeerAttributes, t: typedesc[T]): T {.raises: [KeyError].} =
  pa{T}.valueOr:
    raise newException(KeyError, "Attritute not found")

proc match*(pa, candidate: PeerAttributes): bool =
  for f in pa.attributes:
    block oneAttribute:
      for field in candidate.attributes:
        if field.comparator(field, f):
          break oneAttribute
      return false
  return true

type
  PeerFoundCallback* = proc(pa: PeerAttributes) {.raises: [], gcsafe.}

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
  DiscoveryFinished* = object of LPError

  DiscoveryQuery* = ref object
    attr: PeerAttributes
    peers: AsyncQueue[PeerAttributes]
    finished: bool
    futs: seq[Future[void]]

  DiscoveryManager* = ref object
    interfaces: seq[DiscoveryInterface]
    queries: seq[DiscoveryQuery]

proc add*(dm: DiscoveryManager, di: DiscoveryInterface) =
  dm.interfaces &= di

  di.onPeerFound = proc(pa: PeerAttributes) =
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
  dm.queries.add(query)
  dm.queries.keepItIf(it.futs.anyIt(not it.finished()))
  return query

proc request*[T](dm: DiscoveryManager, value: T): DiscoveryQuery =
  var pa: PeerAttributes
  pa.add(value)
  return dm.request(pa)

proc advertise*[T](dm: DiscoveryManager, value: T) =
  for i in dm.interfaces:
    i.toAdvertise.add(value)
    if i.advertiseLoop.isNil:
      i.advertisementUpdated = newAsyncEvent()
      i.advertiseLoop = i.advertise()
    else:
      i.advertisementUpdated.fire()

template forEach*(query: DiscoveryQuery, code: untyped) =
  ## Will execute `code` for each discovered peer. The
  ## peer attritubtes are available through the variable
  ## `peer`

  proc forEachInternal(q: DiscoveryQuery) {.async.} =
    while true:
      let peer {.inject.} =
        try:
          await q.getPeer()
        except DiscoveryFinished:
          return
      code

  asyncSpawn forEachInternal(query)

proc stop*(query: DiscoveryQuery) =
  query.finished = true
  for r in query.futs:
    if not r.finished():
      r.cancel()

proc stop*(dm: DiscoveryManager) =
  for q in dm.queries:
    q.stop()
  for i in dm.interfaces:
    if isNil(i.advertiseLoop):
      continue
    i.advertiseLoop.cancel()

proc getPeer*(query: DiscoveryQuery): Future[PeerAttributes] {.async.} =
  let getter = query.peers.popFirst()

  try:
    await getter or allFinished(query.futs)
  except CancelledError as exc:
    getter.cancel()
    raise exc

  if not finished(getter):
    if query.finished:
      raise newException(DiscoveryFinished, "Discovery query stopped")
    # discovery loops only finish when they don't handle the query
    raise newException(DiscoveryError, "Unable to find any peer matching this request")
  return await getter

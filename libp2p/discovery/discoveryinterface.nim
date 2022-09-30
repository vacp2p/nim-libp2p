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

import tables, macros
import chronos,
       chronicles
import ../peerid,
       ../multiaddress,
       ../errors

#TODO should this be moved to discoverymngr.nim?
type
  DiscoveryError* = object of LPError

  BaseFilter = ref object of RootObj
    comparator*: proc(f: BaseFilter, c: BaseFilter): bool {.gcsafe, raises: [Defect].}

  Filter[T] = ref object of BaseFilter
    value*: T

  #TODO find better name
  DiscoveryFilters* = object
    filters: seq[BaseFilter]

  DiscoveryService* = distinct string

proc `==`*(a, b: DiscoveryService): bool {.borrow.}

proc add*[T](df: var DiscoveryFilters,
             value: T) =
  df.filters.add(Filter[T](
      value: value,
      comparator: proc(f: BaseFilter, c: BaseFilter): bool =
        if f is Filter[T] and c is Filter[T]:
          Filter[T](f).value == Filter[T](c).value
        else:
          false
    )
  )

proc ofType*[T](f: BaseFilter, _: type[T]): bool =
  return f is Filter[T]

proc to*[T](f: BaseFilter, _: type[T]): T =
  Filter[T](f).value

iterator items*(df: DiscoveryFilters): BaseFilter =
  for f in df.filters:
    yield f

proc `[]`*[T](df: DiscoveryFilters, t: typedesc[T]): seq[T] =
  for f in df.filters:
    if f is Filter[T]:
      result.add Filter[T](f).value

proc match*(filter, candidate: DiscoveryFilters): bool =
  for f in filter.filters:
    block oneFilter:
      for field in candidate.filters:
        if field.comparator(field, f):
          break oneFilter
      return false
  return true

type
  PeerFoundCallback* = proc(res: DiscoveryFilters) {.raises: [Defect], gcsafe.}

  DiscoveryInterface* = ref object of RootObj
    onPeerFound*: PeerFoundCallback
    toAdvertise*: DiscoveryFilters
    advertisementUpdated*: AsyncEvent
    advertiseLoop*: Future[void]

method request*(self: DiscoveryInterface, filter: DiscoveryFilters) {.async, base.} =
  doAssert(false, "Not implemented!")

method advertise*(self: DiscoveryInterface) {.async, base.} =
  doAssert(false, "Not implemented!")

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

import tables, sequtils, macros
import chronos,
       chronicles
import ../peerid,
       ../multiaddress,
       ../errors

type
  DiscoveryError* = object of LPError

  BaseFilter = ref object of RootObj
    comparator*: proc(f: BaseFilter, c: BaseFilter): bool

  Filter[T] = ref object of BaseFilter
    filter*: T
  
  DiscoveryFilter* = Table[string, BaseFilter]

macro getTypeName(t: type): untyped =
  let typ = getTypeImpl(t)[1]
  newLit(repr(typ.owner()) & "." & repr(typ))

proc `[]=`*[T](df: var DiscoveryFilter,
               t: typedesc[T],
               filter: T) =
  let name = getTypeName(T)
  df.add(name, Filter[T](
      filter: filter,
      comparator: proc(f: BaseFilter, c: BaseFilter): bool =
        if f is Filter[T] and c is Filter[T]:
          Filter[T](f).filter == Filter[T](c).filter
        else:
          false
    )
  )

proc `[]`*[T](df: DiscoveryFilter, t: typedesc[T]): T =
  let name = getTypeName(T)
  result = Filter[T](df.getOrDefault(name)).filter

type
  DiscoveryResult* = ref object of RootObj
    peerId*: PeerId
    addresses*: seq[MultiAddress]

  PeerFoundCallback* = proc(res: DiscoveryResult) {.raises: [Defect], gcsafe.}

  DiscoveryInterface* = ref object of RootObj
    onPeerFound*: PeerFoundCallback

method request*(self: DiscoveryInterface, filter: DiscoveryFilter) {.async, base.} =
  doAssert(false, "Not implemented!")

method advertise*(self: DiscoveryInterface, filter: DiscoveryFilter) {.async, base.} =
  doAssert(false, "Not implemented!")

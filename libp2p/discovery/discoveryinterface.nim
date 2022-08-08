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

import tables, sequtils
import chronos,
       chronicles
import ../peerid,
       ../multiaddress,
       ../errors

type
  DiscoveryError* = object of LPError

  BaseFilter = ref object of RootObj

  Filter[T] = ref object of BaseFilter
    filter*: T
  
  FilterTuple = tuple
    key: string
    value: string

  NamespaceFilter* = ref object of Filter[string]
  PeerIdFilter* = ref object of Filter[PeerId]
  KeyValueFilter* = ref object of Filter[FilterTuple]
  DiscoveryFilter* = seq[BaseFilter]

proc `[]`*[T](df: DiscoveryFilter, filter: typedesc[T]): seq[T] =
  df.filterIt(it of filter).mapIt(filter(it))

proc addFilter*[T](df: var DiscoveryFilter, filter: T) =
  when T is string:
    df.add(NamespaceFilter(filter: filter))
  elif T is PeerId:
    df.add(PeerIdFilter(filter: filter))
  elif T is FilterTuple:
    df.add(TestFilter(filter: filter))
  else:
    {.fatal: "Must be a filtrable element".}

type
  DiscoveryResult* = object
    peerId*: PeerId
    addresses*: seq[MultiAddress]
    filter*: DiscoveryFilter

  PeerFoundCallback* = proc(filter: DiscoveryResult)

  DiscoveryInterface* = ref object of RootObj
    onPeerFound*: PeerFoundCallback

method request(self: DiscoveryInterface, filter: DiscoveryFilter) {.async, base.} =
  doAssert(false, "Not implemented!")

method advertise(self: DiscoveryInterface) {.async, base.} =
  doAssert(false, "Not implemented!")

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sequtils
import chronos, results
import ../../../alloc
import ../../../../libp2p
import ../../../../libp2p/extended_peer_record
import ../../../../libp2p/protocols/kademlia
import ../../../../libp2p/protocols/service_discovery
import ./libp2p_kademlia_requests

type ServiceDiscoveryMsgType* = enum
  SD_START
  SD_STOP
  SD_START_ADVERTISING
  SD_STOP_ADVERTISING
  SD_START_DISCOVERING
  SD_STOP_DISCOVERING
  SD_LOOKUP

type ServiceDiscoveryRequest* = object
  operation: ServiceDiscoveryMsgType
  serviceId: cstring
  serviceData: SharedSeq[byte]

proc createShared*(
    T: type ServiceDiscoveryRequest,
    op: ServiceDiscoveryMsgType,
    serviceId: cstring = "",
    serviceData: ptr byte = nil,
    serviceDataLen: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].serviceId = serviceId.alloc()
  ret[].serviceData = allocSharedSeqFromCArray(serviceData, serviceDataLen.int)
  return ret

proc destroyShared*(self: ptr ServiceDiscoveryRequest) =
  deallocShared(self[].serviceId)
  deallocSharedSeq(self[].serviceData)
  deallocShared(self)

proc process*(
    self: ptr ServiceDiscoveryRequest, kadOpt: Opt[KadDHT]
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let kad = kadOpt.valueOr:
    return err("service discovery not initialized")

  if not (kad of ServiceDiscovery):
    return err("service discovery not mounted")

  let disco = ServiceDiscovery(kad)

  case self.operation
  of SD_START:
    await disco.start()
  of SD_STOP:
    await disco.stop()
  of SD_START_ADVERTISING:
    let service = ServiceInfo(id: $self[].serviceId, data: self[].serviceData.toSeq())
    disco.startAdvertising(service)
  of SD_STOP_ADVERTISING:
    await disco.stopAdvertising($self[].serviceId)
  of SD_START_DISCOVERING:
    discard disco.startDiscovering($self[].serviceId)
  of SD_STOP_DISCOVERING:
    disco.stopDiscovering($self[].serviceId)
  of SD_LOOKUP:
    raiseAssert "unsupported path, use processLookup"

  ok()

proc processLookup*(
    self: ptr ServiceDiscoveryRequest, kadOpt: Opt[KadDHT]
): Future[Result[ptr RandomRecordsResult, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let kad = kadOpt.valueOr:
    return err("service discovery not initialized")

  if not (kad of ServiceDiscovery):
    return err("service discovery not mounted")

  let disco = ServiceDiscovery(kad)
  let service = ServiceInfo(id: $self[].serviceId, data: self[].serviceData.toSeq())
  let res = await disco.lookup(service)
  let ads = res.valueOr:
    return err($error)

  buildRandomRecordsResult(ads.mapIt(it.data))

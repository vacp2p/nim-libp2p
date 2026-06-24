# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sequtils
import chronos, results
import ../../../[types, ffi_types, alloc]
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
  SD_REGISTER_INTEREST
  SD_UNREGISTER_INTEREST
  SD_LOOKUP
  SD_CREATE_XPR

type SharedService = object
  id: cstring
  data: SharedSeq[byte]

type ServiceDiscoveryRequest* = object
  operation: ServiceDiscoveryMsgType
  serviceId: cstring
  serviceData: SharedSeq[byte]
  addrs: SharedSeq[cstring]
  services: ptr UncheckedArray[SharedService]
  servicesLen: int
  seqNo: uint64

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

proc createSharedXpr*(
    T: type ServiceDiscoveryRequest,
    addrs: ptr cstring,
    addrsLen: csize_t,
    services: ptr Libp2pServiceInfo,
    servicesLen: csize_t,
    seqNo: uint64,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = SD_CREATE_XPR
  ret[].addrs = allocSharedSeqFromCArray(addrs, addrsLen.int)
  ret[].seqNo = seqNo
  ret[].servicesLen = servicesLen.int

  if servicesLen > 0 and not services.isNil():
    ret[].services = cast[ptr UncheckedArray[SharedService]](allocShared0(
      sizeof(SharedService) * servicesLen.int
    ))
    let src = cast[ptr UncheckedArray[Libp2pServiceInfo]](services)
    for i in 0 ..< servicesLen.int:
      ret[].services[i].id = src[i].id.alloc()
      ret[].services[i].data = allocSharedSeqFromCArray(src[i].data, src[i].dataLen.int)

  return ret

proc destroyShared*(self: ptr ServiceDiscoveryRequest) =
  if not self[].serviceId.isNil():
    deallocShared(self[].serviceId)
  deallocSharedSeq(self[].serviceData)
  deallocSharedSeq(self[].addrs)

  if not self[].services.isNil():
    for i in 0 ..< self[].servicesLen:
      if not self[].services[i].id.isNil():
        deallocShared(self[].services[i].id)
      deallocSharedSeq(self[].services[i].data)
    deallocShared(self[].services)

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
    let service =
      ServiceInfo(id: $self[].serviceId, data: Opt.some(self[].serviceData.toSeq()))
    disco.startAdvertising(service)
  of SD_STOP_ADVERTISING:
    await disco.stopAdvertising($self[].serviceId)
  of SD_REGISTER_INTEREST:
    discard disco.registerInterest($self[].serviceId)
  of SD_UNREGISTER_INTEREST:
    disco.unregisterInterest($self[].serviceId)
  of SD_LOOKUP:
    raiseAssert "unsupported path, use processLookup"
  of SD_CREATE_XPR:
    raiseAssert "unsupported path, use processCreateXpr"

  ok()

proc toServices(self: ptr ServiceDiscoveryRequest): seq[ServiceInfo] =
  var services: seq[ServiceInfo]
  for i in 0 ..< self[].servicesLen:
    services.add(
      ServiceInfo(id: $self[].services[i].id, data: self[].services[i].data.toSeq())
    )
  services

proc toAddresses(self: ptr ServiceDiscoveryRequest): Result[seq[MultiAddress], string] =
  var addresses: seq[MultiAddress]
  for address in self[].addrs.toSeq():
    let ma = MultiAddress.init($address).valueOr:
      return err("invalid multiaddress '" & $address & "': " & $error)
    addresses.add(ma)
  ok(addresses)

proc processCreateXpr*(
    self: ptr ServiceDiscoveryRequest, libp2p: ptr LibP2P
): Future[Result[ptr ReadResponse, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let peerInfo = libp2p[].switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")

  var addresses = self.toAddresses().valueOr:
    return err(error)
  if addresses.len == 0:
    addresses = peerInfo.addrs

  let seqNo =
    if self[].seqNo == 0:
      Moment.now().epochSeconds.uint64
    else:
      self[].seqNo

  let peerRecord = ExtendedPeerRecord.init(
    peerId = peerInfo.peerId,
    addresses = addresses,
    seqNo = seqNo,
    services = self.toServices(),
  )

  let xpr = SignedExtendedPeerRecord.build(peerInfo.privateKey, peerRecord).valueOr:
    return err(error)

  ok(allocReadResponse(xpr.encode()))

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
  let service =
    ServiceInfo(id: $self[].serviceId, data: Opt.some(self[].serviceData.toSeq()))
  let res = await disco.lookup(service)
  let ads = res.valueOr:
    return err($error)

  buildRandomRecordsResult(ads.mapIt(it.data))

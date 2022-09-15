# Nim-LibP2P
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils, strutils, tables]
import pkg/[
  chronos, chronicles, nat_mapper
]
import ../protocol,
       ../../peerinfo,
       ../../multiaddress,
       ../../wire,
       ../../multicodec

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

logScope:
  topics = "libp2p nat_auto_mapper"

type
  NatAutoMapper* = ref object of LPProtocol
    mappingManager*: MappingManager
    peerInfo*: PeerInfo

proc toPortMappings(mas: seq[MultiAddress]): Table[MultiAddress, PortMapping] =
  for ma in mas:
    let ta = initTAddress(ma)
    if ta.isErr: continue
    try:
      if ta.get().address() != IPv4_any(): continue
    except ValueError: continue

    var mapping = PortMapping(port: ta.get.port.int)

    if (multiCodec("udp") in ma) == MaResult[bool].ok(true):
      mapping.protocol = NatProtocolType.Udp
      result[ma] = mapping
    elif (multiCodec("tcp") in ma) == MaResult[bool].ok(true):
      mapping.protocol = NatProtocolType.Tcp
      result[ma] = mapping

proc mapAddress(p: NatAutoMapper, addrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
  debug "Mapping addresses", addrs
  try:
    let mappings = addrs.toPortMappings()
    if mappings.len == 0:
      return addrs

    var resAddrs = addrs.filterIt(it notin mappings)

    debug "Creating mappings", count=mappings.len
    await p.mappingManager.setMappings(toSeq(mappings.values))

    let
      publicIp = await p.mappingManager.publicIp()
      publicIpMa =
        MultiAddress.init(multiCodec("ip4"), publicIp.address_v4).tryGet()

    for ma, _ in mappings:
      resAddrs &= publicIpMa & ma[1..^1].tryGet()
    return resAddrs
  except CatchableError as exc:
    info "Failed to map addresses", err = exc.msg, addrs
    return addrs

method stop*(p: NatAutoMapper) {.async.} =
  await procCall LPProtocol(p).stop()
  if not isNil(p.mappingManager):
    await p.mappingManager.stop()

proc new*(T: type[NatAutoMapper], peerInfo: PeerInfo): T =
  let res = T(mappingManager: MappingManager.new(), peerInfo: peerInfo)

  #TODO consider a LPProtocol "early start" instead
  peerInfo.addressMappers &=
    proc(listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
      return await res.mapAddress(listenAddrs)
  res

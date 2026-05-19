# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import stew/endians2
import chronos, chronicles, results
import ../[multiaddress, multicodec]
import ../switch
import ./wildcardresolverservice

logScope:
  topics = "libp2p natservice"

type
  NATMode* = enum
    natModeAuto
      ## Use libp2p-native mechanisms (autonat / hole-punching). No port-mapping
      ## is performed.
      ## TODO: In this skeleton it is a no-op;
    natModeExplicitIp
      ## Static external IP, no probing. The configured `explicitIp` is combined
      ## with the bound listen ports to produce `peerInfo.announcedAddrs`.

  NATConfig* = object
    mode*: NATMode
    explicitIp*: Opt[IpAddress]

  NATService* = ref object of Service
    config: NATConfig
    addressMapper: AddressMapper

proc new*(T: typedesc[NATService], config: NATConfig): T =
  T(config: config)

proc init*(
    T: typedesc[NATConfig],
    mode: NATMode,
    explicitIp: Opt[IpAddress] = Opt.none(IpAddress),
): T =
  T(mode: mode, explicitIp: explicitIp)

proc explicitIpMultiAddrs(
    listenAddrs: seq[MultiAddress], explicitIp: IpAddress
): seq[MultiAddress] =
  ## For each TCP-over-IP or QUIC-v1-over-IP listen address whose family matches
  ## `explicitIp`, emit a copy with the IP swapped to `explicitIp` and the
  ## transport/port preserved. Other addresses are dropped (e.g. memory transport,
  ## or a family mismatch).
  var addrs: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let
      tcpMatch = TCP_IP.matchPartial(listenAddr)
      quicMatch = QUIC_V1_IP.matchPartial(listenAddr)
    if not (tcpMatch or quicMatch):
      continue

    let isIp4 = IP4.matchPartial(listenAddr)
    let isIp6 = IP6.matchPartial(listenAddr)
    if isIp4 and explicitIp.family != IpAddressFamily.IPv4:
      continue
    if isIp6 and explicitIp.family != IpAddressFamily.IPv6:
      continue
    if not (isIp4 or isIp6):
      continue

    let (netCodec, transportProto, isQuic) =
      if tcpMatch:
        (multiCodec("tcp"), tcpProtocol, false)
      else:
        (multiCodec("udp"), udpProtocol, true)

    listenAddr.getProtocolArgument(netCodec).withValue(portArg):
      let port = Port(uint16.fromBytesBE(portArg))
      let base = MultiAddress.init(explicitIp, transportProto, port)
      if isQuic:
        let quicV1 = MultiAddress.init("/quic-v1").valueOr:
          continue
        base.concat(quicV1).withValue(maddress):
          addrs.add(maddress)
      else:
        addrs.add(base)
  addrs

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService", mode = self.config.mode

  case self.config.mode
  of natModeAuto:
    # TODO: wire autonat / hole-punching in here.
    discard
  of natModeExplicitIp:
    let explicitIp = self.config.explicitIp.valueOr:
      raise newException(
        ServiceSetupError, "NATService natModeExplicitIp requires explicitIp to be set"
      )

    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      let announced = explicitIpMultiAddrs(listenAddrs, explicitIp)
      # Freeze the result into announcedAddrs so subsequent expandAddrs short-
      # circuits the mapper chain and downstream consumers see a stable set.
      switch.peerInfo.announcedAddrs = announced
      return announced

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService", mode = self.config.mode
  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  # peerInfo.update is invoked by Switch.start once transports have bound,
  # at which point the mapper runs against the resolved listenAddrs.

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"
  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  # Clear the explicit announce so the switch reverts to mapper-chain output.
  switch.peerInfo.announcedAddrs = @[]
  await switch.peerInfo.update()

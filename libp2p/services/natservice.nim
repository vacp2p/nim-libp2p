# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import ../[multiaddress]
import ../switch

logScope:
  topics = "libp2p natservice"

type
  NATMode* = enum
    natModeAuto
      ## Use libp2p-native mechanisms (autonat / hole-punching). No port-mapping
      ## is performed.
      ## TODO: In this skeleton it is a no-op;
    natModeExplicitIp
      ## Static external IP, no probing. The configured ``explicitIp`` is combined
      ## with the bound listen addresses to produce the announced address set.

  NATConfig* = object
    case mode*: NATMode
    of natModeExplicitIp:
      explicitIp*: IpAddress
    of natModeAuto:
      discard

  NATService* = ref object of Service
    config: NATConfig
    addressMapper: AddressMapper

proc new*(T: typedesc[NATService], config: NATConfig): T =
  T(config: config)

proc explicitIpMapped(
    listenAddrs: seq[MultiAddress], explicitIp: IpAddress
): seq[MultiAddress] =
  ## For each listen address that carries an IP component matching the family
  ## of ``explicitIp``, emit a copy with the IP swapped to ``explicitIp``.
  ## Transport, port, and any suffix (e.g. ``/quic-v1``, ``/ws``, ``/wss``,
  ## ``/tls/ws``) are preserved. Addresses without an IP component, or with a
  ## mismatching family, are dropped.
  var addrs: seq[MultiAddress]
  for listenAddr in listenAddrs:
    listenAddr.replaceIp(explicitIp).withValue(remapped):
      addrs.add(remapped)
  addrs

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService", mode = self.config.mode

  case self.config.mode
  of natModeAuto:
    # TODO: wire autonat / hole-punching in here.
    discard
  of natModeExplicitIp:
    let explicitIp = self.config.explicitIp
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      return explicitIpMapped(listenAddrs, explicitIp)

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
  # Do not touch peerInfo.announcedAddrs here: those may have been set by the
  # user via withAnnouncedAddresses, and triggering peerInfo.update during
  # shutdown can cause observers (e.g. IdentifyPusher) to broadcast while the
  # switch is tearing down.

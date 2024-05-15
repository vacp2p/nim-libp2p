# Nim-LibP2P
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[deques, sequtils]
import stew/[byteutils, results, endians2]
import chronos, chronos/transports/[osnet, ipnet], metrics
import ../[multiaddress, multicodec]
import ../switch
import ../wire
import ../utils/heartbeat
import ../crypto/crypto

logScope:
  topics = "libp2p wildcardresolverservice"

type
  # This type is used to resolve wildcard addresses of the type "0.0.0.0" for IPv4 or "::" for IPv6.
  WildcardAddressResolverService* = ref object of Service
    # Used to get the list of network addresses.
    networkInterfaceProvider: NetworkInterfaceProvider
    # An implementation of an address mapper that takes a list of listen addresses and expands each wildcard address
    # to the respective list of interface addresses. As an example, if the listen address is 0.0.0.0:4001
    # and the machine has 2 interfaces with IPs 172.217.11.174 and 64.233.177.113, the address mapper will
    # expand the wildcard address to 172.217.11.174:4001 and 64.233.177.113:4001.
    addressMapper: AddressMapper
    # Represents the task that is scheduled to run the service.
    scheduleHandle: Future[void]
    # The interval at which the service should run.
    scheduleInterval: Opt[Duration]

  NetworkInterfaceProvider* = ref object of RootObj

proc isLoopbackOrUp(networkInterface: NetworkInterface): bool =
  if (networkInterface.ifType == IfSoftwareLoopback) or
      (networkInterface.state == StatusUp): true else: false

## This method retrieves the addresses of network interfaces based on the specified address family.
##
## The `getAddresses` method filters the available network interfaces to include only
## those that are either loopback or up. It then collects all the addresses from these
## interfaces and filters them to match the provided address family.
##
## Parameters:
## - `networkInterfaceProvider`: A provider that offers access to network interfaces.
## - `addrFamily`: The address family to filter the network addresses (e.g., `AddressFamily.IPv4` or `AddressFamily.IPv6`).
##
## Returns:
## - A sequence of `InterfaceAddress` objects that match the specified address family.
method getAddresses*(
    networkInterfaceProvider: NetworkInterfaceProvider, addrFamily: AddressFamily
): seq[InterfaceAddress] {.base.} =
  let
    interfaces = getInterfaces().filterIt(it.isLoopbackOrUp())
    flatInterfaceAddresses = concat(interfaces.mapIt(it.addresses))
    filteredInterfaceAddresses =
      flatInterfaceAddresses.filterIt(it.host.family == addrFamily)
  return filteredInterfaceAddresses

proc new*(
    T: typedesc[WildcardAddressResolverService],
    scheduleInterval: Opt[Duration] = Opt.none(Duration),
    networkInterfaceProvider: NetworkInterfaceProvider = new(NetworkInterfaceProvider),
): T =
  return T(
    scheduleInterval: scheduleInterval,
    networkInterfaceProvider: networkInterfaceProvider,
  )

proc schedule(
    service: WildcardAddressResolverService, switch: Switch, interval: Duration
) {.async.} =
  heartbeat "Scheduling WildcardAddressResolverService run", interval:
    await service.run(switch)

proc getProtocolArgument*(ma: MultiAddress, codec: MultiCodec): MaResult[seq[byte]] =
  var buffer: seq[byte]
  for item in ma:
    let
      ritem = ?item
      code = ?ritem.protoCode()
    if code == codec:
      let arg = ?ritem.protoAddress()
      return ok(arg)

  err("Multiaddress codec has not been found")

proc getWildcardMultiAddresses(
    interfaceAddresses: seq[InterfaceAddress],
    protocol: Protocol,
    port: Port,
    suffix: MultiAddress,
): seq[MultiAddress] =
  var addresses: seq[MultiAddress]
  for ifaddr in interfaceAddresses:
    var address = ifaddr.host
    address.port = port
    MultiAddress.init(address, protocol).toOpt.withValue(maddress):
      maddress.concat(suffix).toOpt.withValue(a):
        addresses.add(a)
  addresses

proc getWildcardAddress(
    maddress: MultiAddress,
    multiCodec: MultiCodec,
    anyAddr: openArray[uint8],
    addrFamily: AddressFamily,
    port: Port,
    networkInterfaceProvider: NetworkInterfaceProvider,
    peerId: MultiAddress,
): seq[MultiAddress] =
  var addresses: seq[MultiAddress]
  maddress.getProtocolArgument(multiCodec).toOpt.withValue(address):
    if address == anyAddr:
      let filteredInterfaceAddresses = networkInterfaceProvider.getAddresses(addrFamily)
      addresses.add(
        getWildcardMultiAddresses(filteredInterfaceAddresses, IPPROTO_TCP, port, peerId)
      )
    else:
      maddress.concat(peerId).toOpt.withValue(a):
        addresses.add(a)
  return addresses

proc expandWildcardAddresses(
    networkInterfaceProvider: NetworkInterfaceProvider,
    peerId: PeerId,
    listenAddrs: seq[MultiAddress],
): seq[MultiAddress] =
  let peerIdMa = MultiAddress.init(multiCodec("p2p"), peerId).valueOr:
    return default(seq[MultiAddress])

  var addresses: seq[MultiAddress]
  # In this loop we expand bounded addresses like `0.0.0.0` and `::` to list of interface addresses.
  for listenAddr in listenAddrs:
    if TCP_IP.matchPartial(listenAddr):
      listenAddr.getProtocolArgument(multiCodec("tcp")).toOpt.withValue(portArg):
        if len(portArg) == sizeof(uint16):
          let port = Port(uint16.fromBytesBE(portArg))
          if IP4.matchPartial(listenAddr):
            let wildcardAddresses = getWildcardAddress(
              listenAddr,
              multiCodec("ip4"),
              AnyAddress.address_v4,
              AddressFamily.IPv4,
              port,
              networkInterfaceProvider,
              peerIdMa,
            )
            addresses.add(wildcardAddresses)
          elif IP6.matchPartial(listenAddr):
            let wildcardAddresses = getWildcardAddress(
              listenAddr,
              multiCodec("ip6"),
              AnyAddress6.address_v6,
              AddressFamily.IPv6,
              port,
              networkInterfaceProvider,
              peerIdMa,
            )
            addresses.add(wildcardAddresses)
          else:
            listenAddr.concat(peerIdMa).withValue(ma):
              addresses.add(ma)
    else:
      let suffixed = listenAddr.concat(peerIdMa).valueOr:
        continue
      addresses.add(suffixed)
  addresses

method setup*(
    self: WildcardAddressResolverService, switch: Switch
): Future[bool] {.async.} =
  self.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async.} =
    echo listenAddrs
    return expandWildcardAddresses(
      self.networkInterfaceProvider, switch.peerInfo.peerId, listenAddrs
    )

  debug "Setting up WildcardAddressResolverService"
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    self.scheduleInterval.withValue(interval):
      self.scheduleHandle = schedule(self, switch, interval)
    switch.peerInfo.addressMappers.add(self.addressMapper)
  return hasBeenSetup

method run*(self: WildcardAddressResolverService, switch: Switch) {.async, public.} =
  trace "Running WildcardAddressResolverService"
  await switch.peerInfo.update()

method stop*(
    self: WildcardAddressResolverService, switch: Switch
): Future[bool] {.async, public.} =
  debug "Stopping WildcardAddressResolverService"
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    if not isNil(self.scheduleHandle):
      self.scheduleHandle.cancel()
      self.scheduleHandle = nil
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    await switch.peerInfo.update()
  return hasBeenStopped

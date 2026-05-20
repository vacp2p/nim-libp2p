# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import chronos, chronos/transports/[osnet, ipnet], chronicles, results
import ../[multiaddress]
import ../switch

logScope:
  topics = "libp2p wildcardresolverservice"

type
  WildcardAddressResolverService* = ref object of Service
    ## Service used to resolve wildcard addresses of the type "0.0.0.0" for IPv4 or "::" for IPv6.
    networkInterfaceProvider: NetworkInterfaceProvider
    ## Provides a list of network addresses.
    addressMapper: AddressMapper
    ## An implementation of an address mapper that takes a list of listen addresses and expands each wildcard address
    ## to the respective list of interface addresses. As an example, if the listen address is 0.0.0.0:4001
    ## and the machine has 2 interfaces with IPs 172.217.11.174 and 64.233.177.113, the address mapper will
    ## expand the wildcard address to 172.217.11.174:4001 and 64.233.177.113:4001.

  NetworkInterfaceProvider* =
    proc(addrFamily: AddressFamily): seq[InterfaceAddress] {.gcsafe, raises: [].}

proc isLoopbackOrUp(networkInterface: NetworkInterface): bool =
  if (networkInterface.ifType == IfSoftwareLoopback) or
      (networkInterface.state == StatusUp): true else: false

proc getAddresses(addrFamily: AddressFamily): seq[InterfaceAddress] =
  ## Retrieves the addresses of network interfaces based on the specified address family.
  ##
  ## It filters the available network interfaces to include only
  ## those that are either loopback or up. It then collects all the addresses from these
  ## interfaces and filters them to match the provided address family.
  ##
  ## Parameters:
  ## - `addrFamily`: The address family to filter the network addresses (e.g., `AddressFamily.IPv4` or `AddressFamily.IPv6`).
  ##
  ## Returns:
  ## - A sequence of `InterfaceAddress` objects that match the specified address family.
  let
    interfaces = getInterfaces().filterIt(it.isLoopbackOrUp())
    flatInterfaceAddresses = concat(interfaces.mapIt(it.addresses))
    filteredInterfaceAddresses =
      flatInterfaceAddresses.filterIt(it.host.family == addrFamily)
  return filteredInterfaceAddresses

proc new*(
    T: typedesc[WildcardAddressResolverService],
    networkInterfaceProvider: NetworkInterfaceProvider = getAddresses,
): T =
  ## This procedure initializes a new `WildcardAddressResolverService` with the provided network interface provider.
  ##
  ## Parameters:
  ## - `T`: The type descriptor for `WildcardAddressResolverService`.
  ## - `networkInterfaceProvider`: A provider that offers access to network interfaces. Defaults to a new instance of `NetworkInterfaceProvider`.
  ##
  ## Returns:
  ## - A new instance of `WildcardAddressResolverService`.
  return T(networkInterfaceProvider: networkInterfaceProvider)

proc isWildcardIp(ip: IpAddress): bool =
  case ip.family
  of IpAddressFamily.IPv4:
    ip.address_v4 == AnyAddress.address_v4
  of IpAddressFamily.IPv6:
    ip.address_v6 == AnyAddress6.address_v6

proc expandWildcardAddresses(
    networkInterfaceProvider: NetworkInterfaceProvider, listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  ## Expand bound wildcard addresses (``0.0.0.0`` / ``::``) into one address
  ## per matching network interface. Non-wildcard addresses are passed through
  ## unchanged. The transport, port, and any suffix (e.g. ``/quic-v1``,
  ## ``/ws``, ``/wss``, ``/tls/ws``) of the listen address are preserved on
  ## the expanded copies.
  var addresses: seq[MultiAddress]
  for listenAddr in listenAddrs:
    if not (TCP_IP.matchPartial(listenAddr) or QUIC_V1_IP.matchPartial(listenAddr)):
      addresses.add(listenAddr)
      continue

    let listenIp = listenAddr.getIp().valueOr:
      addresses.add(listenAddr)
      continue

    if not isWildcardIp(listenIp):
      addresses.add(listenAddr)
      continue

    let families =
      case listenIp.family
      of IpAddressFamily.IPv4:
        @[AddressFamily.IPv4]
      of IpAddressFamily.IPv6:
        # IPv6 dual stack: also expand to IPv4 interfaces.
        @[AddressFamily.IPv6, AddressFamily.IPv4]

    for family in families:
      for ifaddr in networkInterfaceProvider(family):
        listenAddr.replaceIp(ifaddr.host.toIpAddress()).withValue(remapped):
          addresses.add(remapped)
  addresses

method setup*(
    self: WildcardAddressResolverService, switch: Switch
) {.raises: [ServiceSetupError].} =
  ## Sets up the `WildcardAddressResolverService`.
  ##
  ## This method adds the address mapper to the peer's list of address mappers.
  ##
  ## Parameters:
  ## - `self`: The instance of `WildcardAddressResolverService` being set up.
  ## - `switch`: The switch context in which the service operates.
  ##
  ## Returns:
  ## - No value. If setup fails, a `ServiceSetupError` is raised.
  debug "Setting up WildcardAddressResolverService"

  self.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    return expandWildcardAddresses(self.networkInterfaceProvider, listenAddrs)

method start*(
    self: WildcardAddressResolverService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  ## Runs the WildcardAddressResolverService for a given switch.
  ##
  ## It updates the peer information for the provided switch by running the registered address mapper. Any other
  ## address mappers that are registered with the switch will also be run.
  ##
  trace "Running WildcardAddressResolverService"
  switch.peerInfo.addressMappers.add(self.addressMapper)
  await switch.peerInfo.update()

method stop*(
    self: WildcardAddressResolverService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  ## Stops the WildcardAddressResolverService.
  ##
  ## Handles the shutdown process of the WildcardAddressResolverService for a given switch.
  ## It removes the address mapper from the switch's list of address mappers.
  ## It then updates the peer information for the provided switch. Any wildcard address wont be resolved anymore.
  ##
  ## Parameters:
  ## - `self`: The instance of the WildcardAddressResolverService.
  ## - `switch`: The Switch object associated with the service.
  debug "Stopping WildcardAddressResolverService"

  switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  await switch.peerInfo.update()

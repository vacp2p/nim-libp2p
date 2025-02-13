# Nim-LibP2P
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/sequtils
import stew/[byteutils, results, endians2]
import chronos, chronos/transports/[osnet, ipnet], chronicles
import ../[multiaddress, multicodec]
import ../switch

logScope:
  topics = "libp2p wildcardresolverservice"

type
  WildcardAddressResolverService* = ref object of Service
    ## Service used to resolve wildcard addresses of the type "0.0.0.0" for IPv4 or "::" for IPv6.
    ## When used with a `Switch`, this service will be automatically set up and stopped
    ## when the switch starts and stops. This is facilitated by adding the service to the switch's
    ## list of services using the `.withServices(@[svc])` method in the `SwitchBuilder`.
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
    interfaceAddresses: seq[InterfaceAddress], protocol: Protocol, port: Port
): seq[MultiAddress] =
  var addresses: seq[MultiAddress]
  for ifaddr in interfaceAddresses:
    var address = ifaddr.host
    address.port = port
    MultiAddress.init(address, protocol).withValue(maddress):
      addresses.add(maddress)
  addresses

proc getWildcardAddress(
    maddress: MultiAddress,
    addrFamily: AddressFamily,
    port: Port,
    networkInterfaceProvider: NetworkInterfaceProvider,
): seq[MultiAddress] =
  let filteredInterfaceAddresses = networkInterfaceProvider(addrFamily)
  getWildcardMultiAddresses(filteredInterfaceAddresses, IPPROTO_TCP, port)

proc expandWildcardAddresses(
    networkInterfaceProvider: NetworkInterfaceProvider, listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  var addresses: seq[MultiAddress]

  # In this loop we expand bound addresses like `0.0.0.0` and `::` to list of interface addresses.
  for listenAddr in listenAddrs:
    if TCP_IP.matchPartial(listenAddr):
      listenAddr.getProtocolArgument(multiCodec("tcp")).withValue(portArg):
        let port = Port(uint16.fromBytesBE(portArg))
        if IP4.matchPartial(listenAddr):
          listenAddr.getProtocolArgument(multiCodec("ip4")).withValue(ip4):
            if ip4 == AnyAddress.address_v4:
              addresses.add(
                getWildcardAddress(
                  listenAddr, AddressFamily.IPv4, port, networkInterfaceProvider
                )
              )
            else:
              addresses.add(listenAddr)
        elif IP6.matchPartial(listenAddr):
          listenAddr.getProtocolArgument(multiCodec("ip6")).withValue(ip6):
            if ip6 == AnyAddress6.address_v6:
              addresses.add(
                getWildcardAddress(
                  listenAddr, AddressFamily.IPv6, port, networkInterfaceProvider
                )
              )
              # IPv6 dual stack
              addresses.add(
                getWildcardAddress(
                  listenAddr, AddressFamily.IPv4, port, networkInterfaceProvider
                )
              )
            else:
              addresses.add(listenAddr)
        else:
          addresses.add(listenAddr)
    else:
      addresses.add(listenAddr)
  addresses

method setup*(
    self: WildcardAddressResolverService, switch: Switch
): Future[bool] {.async: (raises: [CancelledError, CatchableError]).} =
  ## Sets up the `WildcardAddressResolverService`.
  ##
  ## This method adds the address mapper to the peer's list of address mappers.
  ##
  ## Parameters:
  ## - `self`: The instance of `WildcardAddressResolverService` being set up.
  ## - `switch`: The switch context in which the service operates.
  ##
  ## Returns:
  ## - A `Future[bool]` that resolves to `true` if the setup was successful, otherwise `false`.
  self.addressMapper = proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async.} =
    return expandWildcardAddresses(self.networkInterfaceProvider, listenAddrs)

  debug "Setting up WildcardAddressResolverService"
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  return hasBeenSetup

method run*(
    self: WildcardAddressResolverService, switch: Switch
) {.public, async: (raises: [CancelledError, CatchableError]).} =
  ## Runs the WildcardAddressResolverService for a given switch.
  ##
  ## It updates the peer information for the provided switch by running the registered address mapper. Any other
  ## address mappers that are registered with the switch will also be run.
  ##
  trace "Running WildcardAddressResolverService"
  await switch.peerInfo.update()

method stop*(
    self: WildcardAddressResolverService, switch: Switch
): Future[bool] {.public, async: (raises: [CancelledError, CatchableError]).} =
  ## Stops the WildcardAddressResolverService.
  ##
  ## Handles the shutdown process of the WildcardAddressResolverService for a given switch.
  ## It removes the address mapper from the switch's list of address mappers.
  ## It then updates the peer information for the provided switch. Any wildcard address wont be resolved anymore.
  ##
  ## Parameters:
  ## - `self`: The instance of the WildcardAddressResolverService.
  ## - `switch`: The Switch object associated with the service.
  ##
  ## Returns:
  ## - A future that resolves to `true` if the service was successfully stopped, otherwise `false`.
  debug "Stopping WildcardAddressResolverService"
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    await switch.peerInfo.update()
  return hasBeenStopped

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, chronicles
import ../switch

export NetworkInterfaceProvider, getAddresses

logScope:
  topics = "libp2p wildcardresolverservice"

type WildcardAddressResolverService* = ref object of Service
  ## Hands the `AddressManager` the interfaces it expands a wildcard listen
  ## address ("0.0.0.0" for IPv4, "::" for IPv6) onto.
  networkInterfaceProvider: NetworkInterfaceProvider

proc new*(
    T: typedesc[WildcardAddressResolverService],
    networkInterfaceProvider: NetworkInterfaceProvider = getAddresses,
): T =
  T(networkInterfaceProvider: networkInterfaceProvider)

method setup*(self: WildcardAddressResolverService, switch: Switch) {.raises: [].} =
  debug "Setting up WildcardAddressResolverService"

method start*(
    self: WildcardAddressResolverService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  trace "Running WildcardAddressResolverService"
  switch.addressManager.networkInterfaceProvider = self.networkInterfaceProvider
  await switch.peerInfo.update()

method stop*(
    self: WildcardAddressResolverService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  debug "Stopping WildcardAddressResolverService"
  switch.addressManager.networkInterfaceProvider = nil
  await switch.peerInfo.update()

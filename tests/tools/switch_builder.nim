# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../libp2p/[switch, builders, multiaddress]
import ./[crypto, multiaddress]

export builders

proc makeStandardSwitchBuilder*(addresses: seq[MultiAddress]): SwitchBuilder =
  ## Helper that creates a SwitchBuilder with standard configurations.
  ## Transports are added automatically to match the listen `addresses`.

  var b = SwitchBuilder.new().withRng(rng()).withNoise().withAddresses(addresses)

  # the listen addresses decide which transports to use, deduped across addresses
  var hasQuic, hasTcp, hasWs, hasMemory = false
  for address in addresses:
    if QUIC_V1.match(address):
      hasQuic = true
    elif TCP.match(address):
      hasTcp = true
    elif WebSockets.match(address):
      hasWs = true
    elif Memory.match(address):
      hasMemory = true
    else:
      raiseAssert "could not infer transport from address: " & $address

  if hasQuic:
    b = b.withQuicTransport()
  if hasTcp:
    b = b.withTcpTransport().withMplex()
  if hasWs:
    b = b.withWsTransport().withMplex()
  if hasMemory:
    b = b.withMemoryTransport().withMplex()

  b

proc makeStandardSwitchBuilder*(
    address: MultiAddress = QuicAutoAddress
): SwitchBuilder =
  makeStandardSwitchBuilder(@[address])

proc makeStandardSwitch*(
    address: MultiAddress = QuicAutoAddress
): Switch {.raises: [LPError].} =
  return makeStandardSwitchBuilder(address).build()

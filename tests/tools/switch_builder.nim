# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../libp2p/[switch, builders, multiaddress]
import ./[crypto, multiaddress]

export builders

proc makeStandardSwitchBuilder*(
    address: MultiAddress = QuicAutoAddress
): SwitchBuilder =
  ## Helper that creates a SwitchBuilder with standard configurations.
  ## Transport is added automatically to match the listen `address`.

  var b = SwitchBuilder.new().withRng(rng()).withNoise().withAddress(address)

  # address will decide which transport to use
  if QUIC_V1.match(address):
    b = b.withQuicTransport()
  elif TCP.match(address):
    b = b.withTcpTransport().withMplex()
  elif WebSockets.match(address):
    b = b.withWsTransport().withMplex()
  elif Memory.match(address):
    b = b.withMemoryTransport().withMplex()
  else:
    raiseAssert "could not infer transport from address"

  b

proc makeStandardSwitch*(
    address: MultiAddress = QuicAutoAddress
): Switch {.raises: [LPError].} =
  return makeStandardSwitchBuilder(address).build()

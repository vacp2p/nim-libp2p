# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import
  results, ../../libp2p/[errors, switch, builders, multiaddress, transports/wstransport]
import ./[crypto, multiaddress]

export builders

proc makeStandardSwitchBuilder*(
    address: MultiAddress = QuicAutoAddress
): SwitchBuilder =
  ## Helper that creates Switch with standard configurations.
  ## Transport is added automatically to match listen `address`.

  var b = SwitchBuilder.new().withRng(rng()).withNoise().withAddress(address)

  # address will decide which transport to use
  if QUIC_V1.match(address):
    b = b.withQuicTransport()
  elif TCP.match(address):
    b = b.withTcpTransport().withMplex()
  elif WebSockets.match(address):
    b = b.withTransport(
      proc(transportConfig: TransportConfig): Transport =
        WsTransport.new(transportConfig.upgr, transportConfig.rng)
    )
    b = b.withMplex()
  elif Memory.match(address):
    b = b.withMemoryTransport().withMplex()
  else:
    raiseAssert "could not infere transport from address"

  b

proc makeStandardSwitch*(
    address: MultiAddress = QuicAutoAddress
): Switch {.raises: [LPError].} =
  return makeStandardSwitchBuilder(address).build()

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import
  results,
  ../../libp2p/
    [errors, switch, builders, multiaddress, multicodec, transports/wstransport]
import ./crypto

export builders

type TransportType* {.pure.} = enum
  QUIC
  TCP
  Websocket
  Memory

proc newStandardSwitchBuilder*(
    address: MultiAddress | string = "", transport: TransportType = TransportType.QUIC
): SwitchBuilder =
  ## Helper for common switch configurations.
  ## When address is specified builder will create transport matching address. 
  ## If address in not specified default address for specified transport will be created.

  var b = SwitchBuilder.new().withRng(rng()).withNoise()

  let addrs =
    when address is MultiAddress:
      address
    else:
      if address.len > 0:
        MultiAddress.init(address).valueOr:
          raise newException(LPError, error)
      else:
        case transport
        of TransportType.QUIC:
          MultiAddress.init("/ip4/0.0.0.0/udp/0/quic-v1").valueOr:
            raise newException(LPError, error)
        of TransportType.TCP:
          MultiAddress.init("/ip4/127.0.0.1/tcp/0").valueOr:
            raise newException(LPError, error)
        of TransportType.Websocket:
          MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").valueOr:
            raise newException(LPError, error)
        of TransportType.Memory:
          MultiAddress.init(MemoryAutoAddress).valueOr:
            raise newException(LPError, error)

  b = b.withAddress(addrs)

  # address will decide which transport to use
  if QUIC_V1.match(addrs):
    b = b.withQuicTransport()
  elif TCP.match(addrs):
    b = b.withTcpTransport().withMplex()
  elif WebSockets.match(addrs):
    b = b.withTransport(
      proc(transportConfig: TransportConfig): Transport =
        WsTransport.new(transportConfig.upgr, transportConfig.rng)
    )
    b = b.withMplex()
  elif Memory.match(addrs):
    b = b.withMemoryTransport().withMplex()

  b

proc makeStandardSwitch*(
    address: MultiAddress | string = "", transport: TransportType = TransportType.QUIC
): Switch {.raises: [LPError].} =
  return newStandardSwitchBuilder(address, transport).build()

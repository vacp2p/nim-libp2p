# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import
  ../../libp2p/[
    errors,
    switch,
    builders,
    multiaddress,
    transports/wstransport,
  ]
import ./crypto

type TransportType* {.pure.} = enum
  QUIC
  TCP
  Websocket
  Memory

proc newStandardSwitchBuilder*(
    address = "",
    transport: TransportType = TransportType.TCP,
): SwitchBuilder {.raises: [LPError].} =
  ## Helper for common switch configurations.
  var b = SwitchBuilder
    .new()
    .withRng(rng())
    .withNoise()

  let addr =
    if address.len > 0:
      MultiAddress.init(address).tryGet()
    else:
      case transport
      of TransportType.QUIC:
        MultiAddress.init("/ip4/0.0.0.0/udp/0/quic-v1").tryGet()
      of TransportType.TCP:
        MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()
      of TransportType.Websocket:
        MultiAddress.init("/ip4/127.0.0.1/tcp/0/ws").tryGet()
      of TransportType.Memory:
        MultiAddress.init(MemoryAutoAddress).tryGet()

  b = b.withAddress(addr)

  case transport
  of TransportType.QUIC:
    b = b.withQuicTransport()
  of TransportType.TCP:
    b = b.withTcpTransport().withMplex()
  of TransportType.Websocket:
    b = b.withTransport(
      proc(config: TransportConfig): Transport =
        WsTransport.new(config.upgr, config.rng)
    )
    b = b.withMplex()
  of TransportType.Memory:
    b = b.withMemoryTransport().withMplex()

  b

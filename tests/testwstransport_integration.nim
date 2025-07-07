{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos #, strutils#, sequtils
import chronos/apps/http/httpclient
import
  ../libp2p/[
    stream/connection,
    upgrademngrs/upgrade,
    nameresolving/dnsresolver,
    autotls/service,
    autotls/utils,
    multiaddress,
    switch,
    builders,
    protocols/ping,
    wire,
  ]

from ./helpers import suite, asyncTest, asyncTeardown, checkTrackers, skip, check

suite "WebSocket transport integration":
  teardown:
    checkTrackers()

  asyncTest "switch successfully dials over wss using autotls certificate":
    var ipAddress: IpAddress
    try:
      ipAddress = getPublicIPAddress()
    except:
      skip() # host doesn't have public IPv4 address
      return

    let switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet()])
      .withNameResolver(DnsResolver.new(@[initTAddress("1.1.1.1:53")]))
      .withWsTransport()
      .withYamux()
      .withNoise()
      .build()

    let switch2 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(
        @[
          MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
          MultiAddress.init("/ip4/0.0.0.0/tcp/46556/wss").tryGet(),
        ]
      )
      .withTcpTransport()
      .withWsTransport()
      .withAutotls()
      .withYamux()
      .withNoise()
      .build()

    # Mount ping so protocol negotiation works
    let pingProto = Ping.new()
    switch2.mount(pingProto)

    await switch1.start()
    await switch2.start()
    defer:
      await switch1.stop()
      await switch2.stop()

    # generate the domain for the peer
    # dashed-ip-add-ress.base36peerid.libp2p.direct
    let dashedIpAddr = ($ipAddress).replace(".", "-")
    let serverDns =
      dashedIpAddr & "." & encodePeerId(switch2.peerInfo.peerId) & "." & AutoTLSDNSServer

    # dial over wss
    let conn = await switch1.dial(
      switch2.peerInfo.peerId,
      @[MultiAddress.init("/dns4/" & serverDns & "/tcp/46556/wss").tryGet()],
      @[PingCodec],
    )
    defer:
      await conn.close()
    discard await pingProto.ping(conn)

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

import chronos, strutils, sequtils
import chronos/apps/http/httpclient
import
  ../libp2p/[
    stream/connection,
    upgrademngrs/upgrade,
    autotls/acme/client,
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

  asyncTest "autotls certificate is used when manual tlscertificate is not specified":
    try:
      discard getPublicIPAddress()
    except:
      skip() # host doesn't have public IPv4 address
      return

    let switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet()])
      .withTcpTransport()
      .withWsTransport()
      .withAutotls(
        config = AutotlsConfig.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      )
      .withYamux()
      .withNoise()
      .build()

    let switch2 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet()])
      .withTcpTransport()
      .withWsTransport()
      .withAutotls(
        config = AutotlsConfig.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      )
      .withYamux()
      .withNoise()
      .build()

    await switch1.start()
    await switch2.start()

    defer:
      await switch1.stop()
      await switch2.stop()

    # should succeed
    for addrs in switch1.peerInfo.addrs:
      echo $addrs
      let inaddrs = "/wss" in $addrs
      echo inaddrs
      if not inaddrs:
        continue

    let wssAddrs = switch1.peerInfo.addrs.filterIt("/wss" in $it)
    check wssAddrs.len != 0

    let conn = await switch2.dial(switch1.peerInfo.peerId, wssAddrs, PingCodec)

    let pingProtocol = Ping.new()
    discard await pingProtocol.ping(conn)
    await conn.close()

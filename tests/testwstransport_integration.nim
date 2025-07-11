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

import chronos
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
    wire,
    protocols/ping,
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

    let pingProtocol = Ping.new(rng = newRng())

    let switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet())
      .withTcpTransport()
      .withWsTransport()
      .withAutotls(
        config = AutotlsConfig.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
      )
      .withYamux()
      .withNoise()
      .build()

    # let switch2 = SwitchBuilder
    #   .new()
    #   .withRng(newRng())
    #   .withAddress(MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet())
    #   .withWsTransport()
    #   .withAutotls(
    #     config = AutotlsConfig.new(acmeServerURL = parseUri(LetsEncryptURLStaging))
    #   )
    #   .withYamux()
    #   .withNoise()
    #   .build()

    await switch1.start()
    # await switch2.start()

    # # should succeed
    # let conn =
    #   await switch2.dial(switch1.peerInfo.peerId, switch1.peerInfo.addrs, PingCodec)
    # echo "7"
    # discard await pingProtocol.ping(conn)
    # echo "8"

    defer:
      #   await conn.close()
      await switch1.stop()
    #   await switch2.stop()

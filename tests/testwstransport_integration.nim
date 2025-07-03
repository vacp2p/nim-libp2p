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

when defined(linux) and defined(amd64):
  {.used.}

  suite "WebSocket transport integration":
    teardown:
      checkTrackers()

    asyncTest "autotls certificate is used when manual tlscertificate is not specified":
      try:
        discard getPublicIPAddress()
      except:
        skip() # host doesn't have public IPv4 address
        return

      echo "1"
      let pingProtocol = Ping.new(rng = newRng())

      echo "2"
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
      echo "3"

      let switch2 = SwitchBuilder
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

      echo "4"
      switch1.mount(pingProtocol)

      echo "5"
      await switch1.start()
      echo "5.1"
      # await switch2.start()
      # echo "6"

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

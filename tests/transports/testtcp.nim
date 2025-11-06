# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/byteutils
import
  ../../libp2p/[
    stream/connection,
    transports/transport,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    multicodec,
    errors,
    wire,
    muxers/muxer,
    muxers/mplex/mplex,
  ]
import ../tools/[unittest]
import ./basic_tests
import ./connection_tests
import ./stream_tests
import ./tcp_tests

proc tcpTransProvider(): Transport =
  TcpTransport.new(upgrade = Upgrade())

proc streamProvider(_: Transport, conn: Connection): Muxer =
  Mplex.new(conn)

const
  address = "/ip4/127.0.0.1/tcp/0"
  validAddresses =
    @[
      "/ip4/127.0.0.1/tcp/1234", "/ip6/::1/tcp/1234", "/dns/example.com/tcp/1234",
      "/dns4/example.com/tcp/1234", "/dns6/example.com/tcp/1234",
    ]

  invalidAddresses =
    @[
      "/ip4/127.0.0.1/udp/1234", # UDP instead of TCP
      "/ip4/127.0.0.1/tcp/1234/ws", # TCP with ws (should be handled by WsTransport)
      "/ip4/127.0.0.1/tcp/1234/wss", # TCP with wss (should be handled by WsTransport)
      "/ip4/127.0.0.1", # Missing port
    ]

suite "TCP transport":
  teardown:
    checkTrackers()

  # shared tests with other transports
  basicTransportTest(tcpTransProvider, address, validAddresses, invalidAddresses)
  connectionTransportTest(tcpTransProvider, address)
  streamTransportTest(tcpTransProvider, address, streamProvider)

  # tcp specific tests
  tcpTests()

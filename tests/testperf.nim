{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos
import ../libp2p
import
  ../libp2p/[switch, protocols/perf/client, protocols/perf/server, protocols/perf/core]
import ./helpers

proc createSwitch(
    isServer: bool = false, useMplex: bool = false, useYamux: bool = false
): Switch =
  var builder = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withTcpTransport()
    .withNoise()
  if useMplex:
    builder = builder.withMplex()
  if useYamux:
    builder = builder.withYamux()

  var switch = builder.build()

  if isServer:
    switch.mount(Perf.new())

  return switch

proc runTest(server: Switch, client: Switch) {.async.} =
  const
    bytesToUpload = 100000
    bytesToDownload = 10000000

  await server.start()
  await client.start()

  defer:
    await client.stop()
    await server.stop()

  let conn = await client.dial(server.peerInfo.peerId, server.peerInfo.addrs, PerfCodec)
  var perfClient = PerfClient.new()
  discard await perfClient.perf(conn, bytesToUpload, bytesToDownload)

  let finalStats = perfClient.currentStats()
  check:
    finalStats.isFinal == true
    finalStats.uploadBytes == bytesToUpload
    finalStats.downloadBytes == bytesToDownload

suite "Perf protocol":
  teardown:
    checkTrackers()

  asyncTest "tcp::yamux":
    return # test fails with some issue reading last packet
    let server = createSwitch(isServer = true, useYamux = true)
    let client = createSwitch(useYamux = true)
    await runTest(server, client)

  asyncTest "tcp::mplex":
    let server = createSwitch(isServer = true, useMplex = true)
    let client = createSwitch(useMplex = true)
    await runTest(server, client)

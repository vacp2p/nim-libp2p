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

  let stats = perfClient.currentStats()
  check:
    stats.isFinal == true
    stats.uploadBytes == bytesToUpload
    stats.downloadBytes == bytesToDownload

suite "Perf protocol":
  teardown:
    checkTrackers()

  asyncTest "tcp::yamux":
    let server = createSwitch(isServer = true, useYamux = true)
    let client = createSwitch(useYamux = true)
    await runTest(server, client)

  asyncTest "tcp::mplex":
    let server = createSwitch(isServer = true, useMplex = true)
    let client = createSwitch(useMplex = true)
    await runTest(server, client)

  asyncTest "perf with exception":
    let server = createSwitch(isServer = true, useMplex = true)
    let client = createSwitch(useMplex = true)

    await server.start()
    await client.start()

    defer:
      await client.stop()
      await server.stop()

    let conn =
      await client.dial(server.peerInfo.peerId, server.peerInfo.addrs, PerfCodec)
    var perfClient = PerfClient.new()
    var perfFut: Future[Duration]
    try:
      # start perf future with large download request
      # this will make perf execute for longer so we can cancel it
      perfFut = perfClient.perf(conn, 1.uint64, 1000000000000.uint64)
    except CatchableError:
      discard

    # after some time upload should be finished
    await sleepAsync(50.milliseconds)
    var stats = perfClient.currentStats()
    check:
      stats.isFinal == false
      stats.uploadBytes == 1

    perfFut.cancel() # cancelling future will raise exception
    await sleepAsync(50.milliseconds)

    # after cancelling perf, stats must indicate that it is final one
    stats = perfClient.currentStats()
    check:
      stats.isFinal == true
      stats.uploadBytes == 1

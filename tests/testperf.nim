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
    isServer: bool = false,
    useQuic: bool = false,
    useMplex: bool = false,
    useYamux: bool = false,
): Switch =
  var builder = SwitchBuilder.new()
  builder = builder.withRng(newRng()).withNoise()

  if useQuic:
    builder = builder.withQuicTransport().withAddresses(
        @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
      )
  else:
    builder = builder.withTcpTransport().withAddresses(
        @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
      )

    if useMplex:
      builder = builder.withMplex()
    elif useYamux:
      builder = builder.withYamux()
    else:
      raiseAssert "must use mplex or yamux"

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
  let perfClient = PerfClient.new()
  discard await perfClient.perf(conn, bytesToUpload, bytesToDownload)

  let stats = perfClient.currentStats()
  check:
    stats.isFinal == true
    stats.uploadBytes == bytesToUpload
    stats.downloadBytes == bytesToDownload

proc runTestWithException(server: Switch, client: Switch) {.async.} =
  const
    bytesToUpload = 1.uint64
    bytesToDownload = 10000000000.uint64
      # use large downlaod request which will make perf to execute for longer
      # giving us change to stop it

  await server.start()
  await client.start()
  defer:
    await client.stop()
    await server.stop()

  let conn = await client.dial(server.peerInfo.peerId, server.peerInfo.addrs, PerfCodec)
  let perfClient = PerfClient.new()
  let perfFut = perfClient.perf(conn, bytesToUpload, bytesToDownload)

  # after some time upload should be finished and download should be ongoing
  await sleepAsync(200.milliseconds)
  var stats = perfClient.currentStats()
  check:
    stats.isFinal == false
    stats.uploadBytes == bytesToUpload
    stats.downloadBytes > 0

  perfFut.cancel() # cancelling future will raise exception in perfClient
  await sleepAsync(10.milliseconds)

  # after cancelling perf, stats must indicate that it is final one
  stats = perfClient.currentStats()
  check:
    stats.isFinal == true
    stats.uploadBytes == bytesToUpload
    stats.downloadBytes > 0
    stats.downloadBytes < bytesToDownload # download must not be completed

suite "Perf protocol":
  teardown:
    checkTrackers()

  asyncTest "quic":
    return # nim-libp2p#1482: currently it does not work with quic
    let server = createSwitch(isServer = true, useQuic = true)
    let client = createSwitch(useQuic = true)
    await runTest(server, client)

  asyncTest "tcp::yamux":
    let server = createSwitch(isServer = true, useYamux = true)
    let client = createSwitch(useYamux = true)
    await runTest(server, client)

  asyncTest "tcp::mplex":
    let server = createSwitch(isServer = true, useMplex = true)
    let client = createSwitch(useMplex = true)
    await runTest(server, client)

  asyncTest "perf with exception::yamux":
    let server = createSwitch(isServer = true, useYamux = true)
    let client = createSwitch(useYamux = true)
    await runTestWithException(server, client)

  asyncTest "perf with exception::mplex":
    let server = createSwitch(isServer = true, useMplex = true)
    let client = createSwitch(useMplex = true)
    await runTestWithException(server, client)

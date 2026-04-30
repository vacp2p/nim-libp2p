# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles
import ../../libp2p/builders
import ../unified_testing
import ./measurements

logScope:
  topics = "perf interop"

const
  DefaultUploadBytes = 1_073_741_824'u64
  DefaultDownloadBytes = 1_073_741_824'u64
  DefaultUploadIterations = 10
  DefaultDownloadIterations = 10
  DefaultLatencyIterations = 100
  DialTimeout = 30.seconds

type PerfConfig = object of BaseConfig
  uploadBytes: uint64
  downloadBytes: uint64
  uploadIterations: int
  downloadIterations: int
  latencyIterations: int

proc readPerfConfig(): PerfConfig =
  let baseConfig = readBaseConfig()
  let config = PerfConfig(
    isDialer: baseConfig.isDialer,
    bindIp: baseConfig.bindIp,
    redisAddr: baseConfig.redisAddr,
    testKey: baseConfig.testKey,
    transport: baseConfig.transport,
    secureChannel: baseConfig.secureChannel,
    muxer: baseConfig.muxer,
    testTimeout: baseConfig.testTimeout,
    uploadBytes: parseUint64Env("UPLOAD_BYTES", DefaultUploadBytes),
    downloadBytes: parseUint64Env("DOWNLOAD_BYTES", DefaultDownloadBytes),
    uploadIterations: parseIntEnv("UPLOAD_ITERATIONS", DefaultUploadIterations),
    downloadIterations: parseIntEnv("DOWNLOAD_ITERATIONS", DefaultDownloadIterations),
    latencyIterations: parseIntEnv("LATENCY_ITERATIONS", DefaultLatencyIterations),
  )
  info "Loaded perf interop configuration", config = config
  config

proc runListener(config: PerfConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    sw = buildBaseSwitch(config, tcpFlags = {ServerFlags.TcpNoDelay}).build()

  sw.mountPerf()
  await sw.start()
  defer:
    await sw.stop()

  publishListenerMultiaddr(redisClient, config.testKey, sw)
  info "Published listener multiaddr"

  # Listener stays alive until terminated by the test harness.
  await sleepAsync(100.hours)

proc runDialer(config: PerfConfig) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    sw = buildBaseSwitch(config, tcpFlags = {ServerFlags.TcpNoDelay}).build()

  await sw.start()
  defer:
    await sw.stop()

  let remoteMA =
    await fetchListenerMultiaddr(redisClient, config.testKey, config.testTimeout)
  let remotePeerId =
    try:
      await sw.connect(remoteMA).wait(DialTimeout)
    except AsyncTimeoutError as e:
      raise newException(
        CatchableError,
        "Timeout connecting to listener at " & $remoteMA & ": " & e.msg,
        e,
      )
  info "Connected to listener", remotePeerId, remoteMA

  let
    uploadStats = await runMeasurement(
      sw, remotePeerId, config.uploadBytes, 0'u64, config.uploadIterations
    )
    downloadStats = await runMeasurement(
      sw, remotePeerId, 0'u64, config.downloadBytes, config.downloadIterations
    )
    latencyStats =
      await runMeasurement(sw, remotePeerId, 1'u64, 1'u64, config.latencyIterations)

  printMeasurement("upload", config.uploadIterations, uploadStats, 2, "Gbps")
  printMeasurement("download", config.downloadIterations, downloadStats, 2, "Gbps")
  printMeasurement("latency", config.latencyIterations, latencyStats, 3, "ms")

proc main() =
  let config = readPerfConfig()

  runMain(config.testTimeout):
    if config.isDialer:
      await runDialer(config)
    else:
      await runListener(config)

main()

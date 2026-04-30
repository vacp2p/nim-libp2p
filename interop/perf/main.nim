# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, os
import ../../libp2p/builders
import ../../tests/tools/crypto
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
  DefaultTestTimeout = 600.seconds
  DialTimeout = 30.seconds

type Config = object
  isDialer: bool
  bindIp: string
  redisAddr: string
  testKey: string
  transport: string
  secureChannel: string
  muxer: string
  uploadBytes: uint64
  downloadBytes: uint64
  uploadIterations: int
  downloadIterations: int
  latencyIterations: int
  testTimeout: Duration

proc readConfig(): Config =
  let config = Config(
    isDialer: parseBoolEnv("IS_DIALER", false),
    bindIp: resolveBindIp(getEnv("LISTENER_IP", "0.0.0.0")),
    redisAddr: getEnv("REDIS_ADDR", "redis:6379"),
    testKey: getEnv("TEST_KEY"),
    transport: getEnv("TRANSPORT", "tcp"),
    secureChannel: getEnv("SECURE_CHANNEL", ""),
    muxer: getEnv("MUXER", ""),
    uploadBytes: parseUint64Env("UPLOAD_BYTES", DefaultUploadBytes),
    downloadBytes: parseUint64Env("DOWNLOAD_BYTES", DefaultDownloadBytes),
    uploadIterations: parseIntEnv("UPLOAD_ITERATIONS", DefaultUploadIterations),
    downloadIterations: parseIntEnv("DOWNLOAD_ITERATIONS", DefaultDownloadIterations),
    latencyIterations: parseIntEnv("LATENCY_ITERATIONS", DefaultLatencyIterations),
    testTimeout: parseDurationEnv("TEST_TIMEOUT_SECS", 1.seconds, DefaultTestTimeout),
  )
  info "Loaded perf interop configuration", config
  config

proc createSwitch(config: Config, mountPerfProto: bool): Switch =
  var builder = SwitchBuilder.new().withRng(rng())
  builder.addTransport(
    config.transport, config.bindIp, tcpFlags = {ServerFlags.TcpNoDelay}
  )
  builder.addSecureChannel(config.secureChannel)
  builder.addMuxer(config.muxer)

  let sw = builder.build()
  if mountPerfProto:
    sw.mountPerf()
  sw

proc runListener(config: Config) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    sw = createSwitch(config, mountPerfProto = true)

  await sw.start()
  defer:
    await sw.stop()

  let listenerAddrs = sw.peerInfo.fullAddrs.tryGet()
  if listenerAddrs.len == 0:
    raise newException(CatchableError, "Listener did not expose any listen addresses")

  let listenerAddr = $listenerAddrs[0]
  redisClient.setk(config.testKey & "_listener_multiaddr", listenerAddr)
  info "Published listener multiaddr", listenerAddr

  # Listener stays alive until terminated by the test harness.
  await sleepAsync(100.hours)

proc runDialer(config: Config) {.async.} =
  let
    redisClient = setupRedis(config.redisAddr)
    listenerAddr = await redisClient.pollGet(config.testKey & "_listener_multiaddr")
    sw = createSwitch(config, mountPerfProto = false)

  await sw.start()
  defer:
    await sw.stop()

  let remoteMA = MultiAddress.init(listenerAddr).tryGet()
  let remotePeerId =
    try:
      await sw.connect(remoteMA).wait(DialTimeout)
    except AsyncTimeoutError as e:
      raise newException(
        CatchableError,
        "Timeout connecting to listener at " & listenerAddr & ": " & e.msg,
        e,
      )
  info "Connected to listener", remotePeerId, listenerAddr

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
  let config = readConfig()

  runMain(config.testTimeout):
    if config.isDialer:
      await runDialer(config)
    else:
      await runListener(config)

main()

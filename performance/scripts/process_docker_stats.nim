from times import parse, toTime, toUnix
import strformat
import strutils
import json
import os
import options

type DockerStatsSample = object
  timestamp: float
  cpuPercent: float
  memUsageMB: float
  netRxMB: float
  netTxMB: float

proc parseTimestamp(statsJson: JsonNode): float =
  let isoStr = statsJson["read"].getStr("")
  let mainPart = isoStr[0 ..< ^1] # remove trailing 'Z'
  let parts = mainPart.split(".")
  let dt = parse(parts[0], "yyyy-MM-dd'T'HH:mm:ss")

  var nanos = 0
  if parts.len == 2:
    let nsStr = parts[1]
    let nsStrPadded = nsStr & repeat('0', 9 - nsStr.len)
    nanos = parseInt(nsStrPadded)
  let epochNano = dt.toTime.toUnix * 1_000_000_000 + nanos

  # Return timestamp in seconds since Unix epoch
  return float(epochNano) / 1_000_000_000.0

proc extractCpuRaw(statsJson: JsonNode): (int, int, int) =
  let cpuStats = statsJson["cpu_stats"]
  let precpuStats = statsJson["precpu_stats"]
  let totalUsage = cpuStats["cpu_usage"]["total_usage"].getInt(0)
  let prevTotalUsage = precpuStats["cpu_usage"]["total_usage"].getInt(0)
  let systemUsage = cpuStats["system_cpu_usage"].getInt(0)
  let prevSystemUsage = precpuStats["system_cpu_usage"].getInt(0)
  let numCpus = cpuStats["online_cpus"].getInt(0)
  return (totalUsage - prevTotalUsage, systemUsage - prevSystemUsage, numCpus)

proc calcCpuPercent(cpuDelta: int, systemDelta: int, numCpus: int): float =
  if systemDelta > 0 and cpuDelta > 0 and numCpus > 0:
    return (float(cpuDelta) / float(systemDelta)) * float(numCpus) * 100.0
  else:
    return 0.0

proc extractMemUsageRaw(statsJson: JsonNode): int =
  let memStats = statsJson["memory_stats"]
  return memStats["usage"].getInt(0)

proc extractNetworkRaw(statsJson: JsonNode): (int, int) =
  var netRxBytes = 0
  var netTxBytes = 0
  if "networks" in statsJson:
    for k, v in statsJson["networks"]:
      netRxBytes += v["rx_bytes"].getInt(0)
      netTxBytes += v["tx_bytes"].getInt(0)
  return (netRxBytes, netTxBytes)

proc convertMB(bytes: int): float =
  return float(bytes) / 1024.0 / 1024.0

proc parseDockerStatsLine(line: string): Option[DockerStatsSample] =
  var samples = none(DockerStatsSample)
  if line.len == 0:
    return samples
  try:
    let statsJson = parseJson(line)
    let timestamp = parseTimestamp(statsJson)
    let (cpuDelta, systemDelta, numCpus) = extractCpuRaw(statsJson)
    let cpuPercent = calcCpuPercent(cpuDelta, systemDelta, numCpus)
    let memUsageMB = extractMemUsageRaw(statsJson).convertMB()
    let (netRxRaw, netTxRaw) = extractNetworkRaw(statsJson)
    let netRxMB = netRxRaw.convertMB()
    let netTxMB = netTxRaw.convertMB()
    return some(
      DockerStatsSample(
        timestamp: timestamp,
        cpuPercent: cpuPercent,
        memUsageMB: memUsageMB,
        netRxMB: netRxMB,
        netTxMB: netTxMB,
      )
    )
  except:
    return samples

proc processDockerStatsLog*(inputPath: string): seq[DockerStatsSample] =
  var samples: seq[DockerStatsSample]
  for line in lines(inputPath):
    let sampleOpt = parseDockerStatsLine(line)
    if sampleOpt.isSome:
      samples.add(sampleOpt.get)
  return samples

proc calcRateMBps(curr: float, prev: float, dt: float): float =
  if dt == 0:
    return 0.0
  return ((curr - prev)) / dt

proc writeCsvSeries(samples: seq[DockerStatsSample], outPath: string) =
  var f = open(outPath, fmWrite)
  f.writeLine(
    "timestamp,cpu_percent,mem_usage_mb,download_MBps,upload_MBps,download_MB,upload_MB"
  )
  if samples.len == 0:
    f.close()
    return
  let timeOffset = samples[0].timestamp
  let memOffset = samples[0].memUsageMB
  let rxOffset = samples[0].netRxMB
  let txOffset = samples[0].netTxMB
  var prevRx = samples[0].netRxMB
  var prevTx = samples[0].netTxMB
  var prevTimestamp = samples[0].timestamp - timeOffset
  for s in samples:
    let relTimestamp = s.timestamp - timeOffset
    let dt = relTimestamp - prevTimestamp
    let dlMBps = calcRateMBps(s.netRxMB, prevRx, dt)
    let ulMBps = calcRateMBps(s.netTxMB, prevTx, dt)
    let dlAcc = s.netRxMB - rxOffset
    let ulAcc = s.netTxMB - txOffset
    let memUsage = s.memUsageMB - memOffset
    f.writeLine(
      fmt"{relTimestamp:.2f},{s.cpuPercent:.2f},{memUsage:.2f},{dlMBps:.4f},{ulMBps:.4f},{dlAcc:.4f},{ulAcc:.4f}"
    )
    prevRx = s.netRxMB
    prevTx = s.netTxMB
    prevTimestamp = relTimestamp
  f.close()

proc findInputFiles(dir: string, prefix: string): seq[string] =
  var files: seq[string] = @[]
  for entry in walkDir(dir):
    if entry.kind == pcFile and entry.path.endsWith(".log") and
        entry.path.contains(prefix):
      files.add(entry.path)
  return files

proc main() =
  let dir = getEnv("DOCKER_STATS_DIR", "performance/output")
  let prefix = getEnv("DOCKER_STATS_PREFIX", "docker_stats_")

  let inputFiles = findInputFiles(dir, prefix)
  if inputFiles.len == 0:
    echo "No docker stats files found."
    return

  for inputFile in inputFiles:
    let processedStats = processDockerStatsLog(inputFile)
    let outputCsvPath = inputFile.replace(".log", ".csv")

    writeCsvSeries(processedStats, outputCsvPath)
    echo fmt"Processed stats from {inputFile} written to {outputCsvPath}"

main()

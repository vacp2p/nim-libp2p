import chronos
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
  netRxBytes: int
  netTxBytes: int

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

proc extractCpuPercent(statsJson: JsonNode): float =
  let cpuStats = statsJson["cpu_stats"]
  let precpuStats = statsJson["precpu_stats"]

  let cpuDelta =
    cpuStats["cpu_usage"]["total_usage"].getInt(0) -
    precpuStats["cpu_usage"]["total_usage"].getInt(0)

  let systemDelta =
    cpuStats["system_cpu_usage"].getInt(0) - precpuStats["system_cpu_usage"].getInt(0)

  var cpuPercent = 0.0
  if systemDelta > 0 and cpuDelta > 0:
    let numCpus = cpuStats["online_cpus"].getInt(0)
    cpuPercent = (float(cpuDelta) / float(systemDelta)) * float(numCpus) * 100.0

  return cpuPercent

proc extractMemUsageMB(statsJson: JsonNode): float =
  let memStats = statsJson["memory_stats"]
  let memUsage = memStats["usage"].getInt(0)

  return float(memUsage) / 1024.0 / 1024.0

proc extractNetwork(statsJson: JsonNode): (int, int) =
  var netRxBytes = 0
  var netTxBytes = 0
  if "networks" in statsJson:
    for k, v in statsJson["networks"]:
      netRxBytes += v["rx_bytes"].getInt(0)
      netTxBytes += v["tx_bytes"].getInt(0)
  return (netRxBytes, netTxBytes)

proc parseDockerStatsLine(line: string): Option[DockerStatsSample] =
  var samples = none(DockerStatsSample)
  if line.len == 0:
    return samples
  try:
    let statsJson = parseJson(line)
    let timestamp = parseTimestamp(statsJson)
    let cpuPercent = extractCpuPercent(statsJson)
    let memUsageMB = extractMemUsageMB(statsJson)
    let (netRxBytes, netTxBytes) = extractNetwork(statsJson)
    return some(
      DockerStatsSample(
        timestamp: timestamp,
        cpuPercent: cpuPercent,
        memUsageMB: memUsageMB,
        netRxBytes: netRxBytes,
        netTxBytes: netTxBytes,
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

proc calcRateMBps(curr: int, prev: int, dt: float): float =
  if dt == 0:
    return 0.0
  return (float(curr - prev) / 1024.0 / 1024.0) / dt

proc calcAccumMB(curr: int, offset: int): float =
  return float(curr - offset) / 1024.0 / 1024.0

proc calcMemUsageMB(curr: float, offset: float): float =
  return curr - offset

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
  let rxOffset = samples[0].netRxBytes
  let txOffset = samples[0].netTxBytes
  var prevRx = samples[0].netRxBytes
  var prevTx = samples[0].netTxBytes
  var prevTimestamp = samples[0].timestamp - timeOffset
  for s in samples:
    let relTimestamp = s.timestamp - timeOffset
    let dt = relTimestamp - prevTimestamp
    let dlMBps = calcRateMBps(s.netRxBytes, prevRx, dt)
    let ulMBps = calcRateMBps(s.netTxBytes, prevTx, dt)
    let dlAcc = calcAccumMB(s.netRxBytes, rxOffset)
    let ulAcc = calcAccumMB(s.netTxBytes, txOffset)
    let memUsage = calcMemUsageMB(s.memUsageMB, memOffset)
    f.writeLine(
      fmt"{relTimestamp:.2f},{s.cpuPercent:.2f},{memUsage:.2f},{dlMBps:.4f},{ulMBps:.4f},{dlAcc:.4f},{ulAcc:.4f}"
    )
    prevRx = s.netRxBytes
    prevTx = s.netTxBytes
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

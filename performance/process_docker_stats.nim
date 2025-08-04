import chronos
from times import parse, toTime, toUnix
import strformat
import strutils
import json
import os
import tables

type DockerStatsSample = object
  container: string
  timestamp: float # seconds since start
  cpuPercent: float
  memUsageMB: float
  netRxBytes: int
  netTxBytes: int

proc processDockerStatsLog*(inputPath: string): Table[string, seq[DockerStatsSample]] =
  var samplesByContainer: Table[string, seq[DockerStatsSample]]
  var startMoments: Table[string, Moment]
  if not fileExists(inputPath):
    return samplesByContainer
  for line in lines(inputPath):
    if line.len == 0:
      continue
    try:
      let statsJson = parseJson(line)
      let container =
        if "name" in statsJson:
          statsJson["name"].getStr
        else:
          statsJson["id"].getStr
      # Timestamp
      var relTime: float
      if "read" in statsJson:
        let isoStr = statsJson["read"].getStr
        let mainPart = isoStr[0 ..< isoStr.len - 1] # remove trailing 'Z'
        let parts = mainPart.split(".")
        let dt = parse(parts[0], "yyyy-MM-dd'T'HH:mm:ss")
        var nanos = 0
        if parts.len == 2:
          let nsStr = parts[1]
          let nsStrPadded = nsStr & repeat('0', 9 - nsStr.len)
          nanos = parseInt(nsStrPadded)
        let epochNano = dt.toTime.toUnix * 1_000_000_000 + nanos
        let m = Moment.init(epochNano, Nanosecond)
        if not startMoments.hasKey(container):
          startMoments[container] = m
        relTime = float(milliseconds(m - startMoments[container])) / 1000.0
      else:
        relTime = 0.0

      # CPU calculation
      let cpuStats = statsJson["cpu_stats"]
      let precpuStats = statsJson["precpu_stats"]
      let cpuDelta =
        cpuStats["cpu_usage"]["total_usage"].getInt -
        precpuStats["cpu_usage"]["total_usage"].getInt
      let systemDelta =
        cpuStats["system_cpu_usage"].getInt - precpuStats["system_cpu_usage"].getInt
      var cpuPercent = 0.0
      if systemDelta > 0 and cpuDelta > 0:
        let numCpus = cpuStats["online_cpus"].getInt
        cpuPercent = (float(cpuDelta) / float(systemDelta)) * float(numCpus) * 100.0

      # Memory
      let memStats = statsJson["memory_stats"]
      let memUsage = memStats["usage"].getInt
      let memUsageMB = float(memUsage) / 1024.0 / 1024.0

      # Network (sum all interfaces)
      var netRxBytes = 0
      var netTxBytes = 0
      if "networks" in statsJson:
        for k, v in statsJson["networks"]:
          netRxBytes += v["rx_bytes"].getInt
          netTxBytes += v["tx_bytes"].getInt

      let sample = DockerStatsSample(
        container: container,
        timestamp: relTime,
        cpuPercent: cpuPercent,
        memUsageMB: memUsageMB,
        netRxBytes: netRxBytes,
        netTxBytes: netTxBytes,
      )
      if not samplesByContainer.hasKey(container):
        samplesByContainer[container] = @[]
      samplesByContainer[container].add(sample)
    except:
      discard
  return samplesByContainer

proc writeCsvSeries(samples: seq[DockerStatsSample], outPath: string) =
  var f = open(outPath, fmWrite)
  f.writeLine(
    "timestamp,cpu_percent,mem_usage_mb,download_MBps,upload_MBps,download_MB,upload_MB"
  )
  var prevRx = 0
  var prevTx = 0
  var prevTime = 0.0
  var accRx = 0.0
  var accTx = 0.0
  for i, s in samples:
    var dlMBps = 0.0
    var ulMBps = 0.0
    if i > 0:
      let dt = s.timestamp - prevTime
      if dt > 0:
        dlMBps = (float(s.netRxBytes - prevRx) / 1024.0 / 1024.0) / dt
        ulMBps = (float(s.netTxBytes - prevTx) / 1024.0 / 1024.0) / dt
    accRx = float(s.netRxBytes) / 1024.0 / 1024.0
    accTx = float(s.netTxBytes) / 1024.0 / 1024.0
    f.writeLine(
      fmt"{s.timestamp:.2f},{s.cpuPercent:.2f},{s.memUsageMB:.2f},{dlMBps:.4f},{ulMBps:.4f},{accRx:.4f},{accTx:.4f}"
    )
    prevRx = s.netRxBytes
    prevTx = s.netTxBytes
    prevTime = s.timestamp
  f.close()

proc main() =
  let dockerStatsLogPath = "performance/output/docker_stats.log"
  let processedStatsByContainer = processDockerStatsLog(dockerStatsLogPath)
  for container, samples in processedStatsByContainer:
    # Deduplicate by timestamp
    var seenTimestamps = initTable[float, bool]()
    var dedupedSamples: seq[DockerStatsSample] = @[]
    for s in samples:
      if not seenTimestamps.hasKey(s.timestamp):
        seenTimestamps[s.timestamp] = true
        dedupedSamples.add(s)
    let safeName = container.replace("/", "_")
    let outCsvPath = fmt"performance/output/docker_stats_{safeName}.csv"
    writeCsvSeries(dedupedSamples, outCsvPath)
    echo "Processed stats written to ", outCsvPath

main()

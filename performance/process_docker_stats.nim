import chronos
from times import parse, toTime, toUnix
import strformat
import strutils
import json
import os
import tables
import options
import sequtils

type DockerStatsSample = object
  container: string
  timestamp: float # seconds since start
  cpuPercent: float
  memUsageMB: float
  netRxBytes: int
  netTxBytes: int

proc parseTimestamp(
    statsJson: JsonNode, container: string, startMoments: var Table[string, Moment]
): float =
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
    return float(milliseconds(m - startMoments[container])) / 1000.0
  else:
    return 0.0

proc extractCpuPercent(statsJson: JsonNode): float =
  let cpuStats = statsJson["cpu_stats"]
  let precpuStats = statsJson["precpu_stats"]
  let cpuDelta =
    cpuStats["cpu_usage"]["total_usage"].getInt -
    precpuStats["cpu_usage"]["total_usage"].getInt
  let systemDelta =
    cpuStats["system_cpu_usage"].getInt - precpuStats["system_cpu_usage"].getInt
  if systemDelta > 0 and cpuDelta > 0:
    let numCpus = cpuStats["online_cpus"].getInt
    return (float(cpuDelta) / float(systemDelta)) * float(numCpus) * 100.0
  else:
    return 0.0

proc extractMemUsageMB(statsJson: JsonNode): float =
  let memStats = statsJson["memory_stats"]
  let memUsage = memStats["usage"].getInt
  return float(memUsage) / 1024.0 / 1024.0

proc extractNetwork(statsJson: JsonNode): (int, int) =
  var netRxBytes = 0
  var netTxBytes = 0
  if "networks" in statsJson:
    for k, v in statsJson["networks"]:
      netRxBytes += v["rx_bytes"].getInt
      netTxBytes += v["tx_bytes"].getInt
  return (netRxBytes, netTxBytes)

proc parseDockerStatsLine(
    line: string, startMoments: var Table[string, Moment]
): Option[DockerStatsSample] =
  if line.len == 0:
    return none(DockerStatsSample)
  try:
    let statsJson = parseJson(line)
    let container =
      if "name" in statsJson:
        statsJson["name"].getStr
      else:
        statsJson["id"].getStr
    let relTime = parseTimestamp(statsJson, container, startMoments)
    let cpuPercent = extractCpuPercent(statsJson)
    let memUsageMB = extractMemUsageMB(statsJson)
    let (netRxBytes, netTxBytes) = extractNetwork(statsJson)
    return some(
      DockerStatsSample(
        container: container,
        timestamp: relTime,
        cpuPercent: cpuPercent,
        memUsageMB: memUsageMB,
        netRxBytes: netRxBytes,
        netTxBytes: netTxBytes,
      )
    )
  except:
    return none(DockerStatsSample)

proc processDockerStatsLog*(inputPath: string): Table[string, seq[DockerStatsSample]] =
  var samplesByContainer: Table[string, seq[DockerStatsSample]]
  var startMoments: Table[string, Moment]
  if not fileExists(inputPath):
    return samplesByContainer
  for line in lines(inputPath):
    let sampleOpt = parseDockerStatsLine(line, startMoments)
    if sampleOpt.isSome:
      let sample = sampleOpt.get
      if not samplesByContainer.hasKey(sample.container):
        samplesByContainer[sample.container] = @[]
      samplesByContainer[sample.container].add(sample)
  return samplesByContainer

proc writeCsvSeries(samples: seq[DockerStatsSample], outPath: string) =
  var f = open(outPath, fmWrite)
  f.writeLine(
    "timestamp,cpu_percent,mem_usage_mb,download_MBps,upload_MBps,download_MB,upload_MB"
  )
  var prevRx = 0
  var prevTx = 0
  var prevTime = 0.0
  for i, s in samples:
    let dt =
      if i > 0:
        s.timestamp - prevTime
      else:
        0.0
    let dlMBps =
      if i > 0 and dt > 0:
        (float(s.netRxBytes - prevRx) / 1024.0 / 1024.0) / dt
      else:
        0.0
    let ulMBps =
      if i > 0 and dt > 0:
        (float(s.netTxBytes - prevTx) / 1024.0 / 1024.0) / dt
      else:
        0.0
    let accRx = float(s.netRxBytes) / 1024.0 / 1024.0
    let accTx = float(s.netTxBytes) / 1024.0 / 1024.0
    f.writeLine(
      fmt"{s.timestamp:.2f},{s.cpuPercent:.2f},{s.memUsageMB:.2f},{dlMBps:.4f},{ulMBps:.4f},{accRx:.4f},{accTx:.4f}"
    )
    prevRx = s.netRxBytes
    prevTx = s.netTxBytes
    prevTime = s.timestamp
  f.close()

proc findInputFiles(): seq[string] =
  if paramCount() > 0:
    return (1 .. paramCount()).mapIt(paramStr(it)).toSeq
  else:
    var files: seq[string] = @[]
    for entry in walkDir("performance/output"):
      if entry.kind == pcFile and entry.path.endsWith(".log") and
          entry.path.contains("docker_stats_"):
        files.add(entry.path)
    return files

proc processAndWriteStats(inputFiles: seq[string]) =
  if inputFiles.len == 0:
    echo "No docker stats files found."
    return
  for dockerStatsLogPath in inputFiles:
    let processedStatsByContainer = processDockerStatsLog(dockerStatsLogPath)
    let outCsvPath = dockerStatsLogPath.replace(".log", ".csv")
    # Flatten all samples from all containers into one sequence
    var allSamples: seq[DockerStatsSample] = @[]
    for container, samples in processedStatsByContainer:
      allSamples.add(samples)
    writeCsvSeries(allSamples, outCsvPath)
    echo fmt"Processed stats from {dockerStatsLogPath} written to {outCsvPath}"

proc main() =
  let inputFiles = findInputFiles()
  processAndWriteStats(inputFiles)

main()

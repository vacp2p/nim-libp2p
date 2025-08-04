import chronos
import strformat
import json
import os

proc processDockerStatsLog*(inputPath: string): string =
  var log = ""
  if not fileExists(inputPath):
    return "No Docker stats log found."
  for line in lines(inputPath):
    if line.len == 0:
      continue
    try:
      let statsJson = parseJson(line)
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
      let memLimit = memStats["limit"].getInt
      let memPercent =
        if memLimit > 0:
          (float(memUsage) / float(memLimit)) * 100.0
        else:
          0.0

      # Network (sum all interfaces)
      var netRxBytes = 0
      var netTxBytes = 0
      if "networks" in statsJson:
        for k, v in statsJson["networks"]:
          netRxBytes += v["rx_bytes"].getInt
          netTxBytes += v["tx_bytes"].getInt

      let timestamp = Moment.now().epochNanoSeconds()
      let logLine =
        fmt"{timestamp}: CPU={cpuPercent:.2f}%, MEM={memUsage}/{memLimit} ({memPercent:.2f}%), NET_RX={netRxBytes}, NET_TX={netTxBytes}"
      log.add(logLine & "\n")
    except:
      log.add("Failed to parse Docker stats line\n")
  return log

proc main() =
  let dockerStatsLogPath = "performance/output/docker_stats.log"
  let processedStats = processDockerStatsLog(dockerStatsLogPath)
  echo "Docker stats log:\n", processedStats

main()

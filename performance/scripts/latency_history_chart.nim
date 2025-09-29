import algorithm, os, sequtils, strutils
import ../types
import common

type LatencyData = object
  prNumber: int
  scenario: string
  latency: LatencyStats

proc readLatencyCsv(path: string): seq[LatencyData] =
  if not fileExists(path):
    echo "Warning: CSV file not found: " & path
    return @[]

  let lines = readFile(path).splitLines()
  if lines.len < 2:
    echo "Warning: CSV appears empty: " & path
    return @[]

  let prNumber = extractPrNumber(path)
  if prNumber == 0:
    echo "Warning: Invalid PR number in filename: " & path
    return @[]

  var latencyData: seq[LatencyData]
  for i, line in lines:
    if i == 0 or line.len == 0:
      continue
    let cols = line.split(',')
    if cols.len < 7:
      continue

    let scenarioType = extractScenarioType(cols[0])
    if scenarioType != "":
      try:
        let data = LatencyData(
          prNumber: prNumber,
          scenario: scenarioType,
          latency: LatencyStats(
            minLatencyMs: parseFloat(cols[4]),
            maxLatencyMs: parseFloat(cols[5]),
            avgLatencyMs: parseFloat(cols[6]),
          ),
        )
        latencyData.add data
      except ValueError:
        continue

  if latencyData.len == 0:
    echo "Warning: No Base test or QUIC data found in: " & path
  return latencyData

when isMainModule:
  let env = getGitHubEnv()
  let latencyDir = getEnv("LATENCY_HISTORY_PATH", "latency_history")
  if not dirExists(latencyDir):
    raiseAssert "Directory not found: " & latencyDir

  # Find all latency CSV files
  let csvFiles = findCsvFiles(latencyDir).filterIt(
      it.extractFilename.startsWith("pr") and it.endsWith("_latency.csv")
    )

  if csvFiles.len == 0:
    raiseAssert "No pr*_latency.csv files found in " & latencyDir

  # Read and collect all latency data
  var allLatencyData: seq[LatencyData]
  for csvFile in csvFiles:
    let dataList = readLatencyCsv(csvFile)
    for data in dataList:
      if data.prNumber > 0:
        allLatencyData.add data

  if allLatencyData.len == 0:
    echo "Warning: No valid latency data found in any CSV files"
    quit(0)

  # Group data by scenario type and sort chronologically
  let tcpData = allLatencyData.filterIt(it.scenario == "TCP").sortedByIt(it.prNumber)
  let quicData = allLatencyData.filterIt(it.scenario == "QUIC").sortedByIt(it.prNumber)

  # Generate output
  var sections: seq[string]
  sections.add "### Latency History"

  let chartConfig = ChartConfig(colors: defaultColors, width: 500, height: 200)

  # Generate individual charts without legends
  var charts: seq[string]

  if tcpData.len > 0:
    let tcpChartData = tcpData.mapIt(
      (
        it.prNumber, it.latency.minLatencyMs, it.latency.avgLatencyMs,
        it.latency.maxLatencyMs,
      )
    )
    charts.add formatLatencyChart(tcpChartData, "TCP (ms)", chartConfig, false)

  if quicData.len > 0:
    let quicChartData = quicData.mapIt(
      (
        it.prNumber, it.latency.minLatencyMs, it.latency.avgLatencyMs,
        it.latency.maxLatencyMs,
      )
    )
    charts.add formatLatencyChart(quicChartData, "QUIC (ms)", chartConfig, false)

  # Combine charts with single legend
  if charts.len > 0:
    sections.add formatMultipleCharts(charts, @["Min", "Avg", "Max"], chartConfig)

  let markdown = sections.join("\n")
  echo markdown
  writeGitHubOutputs(markdown, env, toJobSummary = true, toComment = true)

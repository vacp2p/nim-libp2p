import algorithm, os, sequtils, strutils
import ../types
import ./common

proc readLatencyCsv(path: string): seq[LatencyChartData] =
  let lines = readFile(path).splitLines()
  if lines.len < 2:
    echo "Warning: CSV appears empty: " & path
    return @[]

  let prNumber = extractPrNumber(path)
  if prNumber == 0:
    echo "Warning: Invalid PR number in filename: " & path
    return @[]

  var latencyData: seq[LatencyChartData]
  for i, line in lines:
    if i == 0 or line.len == 0:
      continue
    let cols = line.split(',')
    if cols.len < 7:
      continue

    let scenarioType = extractScenarioType(cols[0])
    if scenarioType != "":
      try:
        let data = LatencyChartData(
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
    echo "Warning: No TCP or QUIC data found in: " & path
  return latencyData

when isMainModule:
  let env = getGitHubEnv()

  # Find all latency CSV files
  let csvFiles = findCsvFiles(env.latencyHistoryPath).filterIt(
      it.extractFilename.startsWith("pr") and it.endsWith("_latency.csv")
    )

  if csvFiles.len == 0:
    raiseAssert "No pr*_latency.csv files found in " & env.latencyHistoryPath

  # Read and collect all latency data
  var allLatencyData: seq[LatencyChartData]
  for csvFile in csvFiles:
    let dataList = readLatencyCsv(csvFile)
    for data in dataList:
      if data.prNumber > 0:
        allLatencyData.add data

  if allLatencyData.len == 0:
    raiseAssert "No valid latency data found in any CSV files"

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
    charts.add formatLatencyChart(tcpChartData, "TCP", chartConfig, false)

  if quicData.len > 0:
    let quicChartData = quicData.mapIt(
      (
        it.prNumber, it.latency.minLatencyMs, it.latency.avgLatencyMs,
        it.latency.maxLatencyMs,
      )
    )
    charts.add formatLatencyChart(quicChartData, "QUIC", chartConfig, false)

  # Combine charts with single legend
  if charts.len > 0:
    sections.add formatMultipleCharts(charts, @["Min", "Avg", "Max"], chartConfig)

  let markdown = sections.join("\n")
  echo markdown
  writeGitHubOutputs(markdown, env, toJobSummary = true, toComment = true)

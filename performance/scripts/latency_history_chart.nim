import algorithm, os, parsecsv, sequtils, strutils
import ../types
import ./common

proc createLatencyRowHandler(path: string): proc(row: CsvRow): LatencyChartData =
  let prNumber = extractPrNumber(path)
  if prNumber == 0:
    echo "Warning: Invalid PR number in filename: " & path

  return proc(row: CsvRow): LatencyChartData =
    let scenarioType = extractScenarioType(row[0])
    if scenarioType == "":
      raise newException(ValueError, "Ignored scenario type")

    return LatencyChartData(
      prNumber: prNumber,
      scenario: scenarioType,
      latency: LatencyStats(
        minLatencyMs: parseFloat(row[4]),
        maxLatencyMs: parseFloat(row[5]),
        avgLatencyMs: parseFloat(row[6]),
      ),
    )

proc main() =
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
    let dataList = readCsv[LatencyChartData](csvFile, createLatencyRowHandler(csvFile))
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
  writeGitHubSummary(markdown, env)
  writeGitHubComment(markdown, env)

main()

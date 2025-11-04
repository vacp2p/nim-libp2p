# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import algorithm
import parsecsv
import sequtils
import strformat
import strutils
import tables
import ../types
import ./common

const CHARTS_DATA = [
  ResourceChartData(title: "CPU %", yAxis: "CPU %", chartType: ResourceChartType.Cpu),
  ResourceChartData(
    title: "Memory Usage (MB)",
    yAxis: "Memory (MB)",
    chartType: ResourceChartType.Memory,
  ),
  ResourceChartData(
    title: "Network Throughput (MB/s)",
    yAxis: "MB/s",
    chartType: ResourceChartType.NetThroughput,
  ),
  ResourceChartData(
    title: "Total Network Data (MB)", yAxis: "MB", chartType: ResourceChartType.NetTotal
  ),
]

proc csvRowHandler(row: CsvRow): ResourceChartsSample =
  ResourceChartsSample(
    timestamp: parseFloat(row[0]),
    cpuPercent: parseFloat(row[1]),
    memUsageMB: parseFloat(row[2]),
    netRxMB: parseFloat(row[5]),
    netTxMB: parseFloat(row[6]),
    downloadRate: parseFloat(row[3]),
    uploadRate: parseFloat(row[4]),
  )

proc buildSeries(
    runs: seq[TestRun], config: ResourceChartData
): seq[(string, seq[float])] =
  var series: seq[(string, seq[float])]
  for run in runs:
    case config.chartType
    of ResourceChartType.Cpu:
      if run.data.len > 0:
        series.add (run.name, run.data.mapIt(it.cpuPercent))
    of ResourceChartType.Memory:
      if run.data.len > 0:
        series.add (run.name, run.data.mapIt(it.memUsageMB))
    of ResourceChartType.NetThroughput:
      if run.data.len > 0:
        series.add (run.name & " download", run.data.mapIt(it.downloadRate))
        series.add (run.name & " upload", run.data.mapIt(it.uploadRate))
    of ResourceChartType.NetTotal:
      if run.data.len > 0:
        series.add (run.name & " download", run.data.mapIt(it.netRxMB))
        series.add (run.name & " upload", run.data.mapIt(it.netTxMB))
  return series

proc main() =
  let env = getGitHubEnv()
  let outDir = env.sharedVolumePath
  let csvFiles = findCsvFiles(outDir, env.dockerStatsPrefix).sorted

  if csvFiles.len == 0:
    raiseAssert "No docker_stats*.csv files found in " & outDir

  var groups: Table[string, seq[TestRun]]
  for file in csvFiles:
    let data = readCsv[ResourceChartsSample](file, csvRowHandler)
    if data.len > 0:
      let group = extractTestName(file)
      let run = extractTestName(file, keepSuffix = true)
      groups.mgetOrPut(group, @[]).add TestRun(name: run, data: data)

  var outputSections: seq[string]
  for groupName in groups.keys.toSeq.sorted:
    let runs = groups[groupName]
    outputSections.add fmt"### {groupName}"

    for chartData in CHARTS_DATA:
      let chartConfig = ChartConfig(colors: defaultColors, width: 450, height: 300)
      let chart = formatMermaidChart(
        chartData.title & " - " & groupName,
        "Time (s)",
        chartData.yAxis,
        runs.buildSeries(chartData),
        chartConfig,
      )
      if chart.len > 0:
        outputSections.add chart

  let output = outputSections.join("\n")

  echo output
  writeGitHubSummary(output, env)

main()

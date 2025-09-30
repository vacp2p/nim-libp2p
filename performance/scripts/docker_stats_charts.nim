import algorithm, sequtils, strformat, strutils, tables
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

proc readCsv(path: string): seq[ResourceChartsSample] =
  let lines = readFile(path).splitLines()
  var data: seq[ResourceChartsSample]
  for i, line in lines:
    if i == 0 or line.len == 0:
      continue
    let cols = line.split(',')
    if cols.len < 7:
      continue
    try:
      data.add(
        ResourceChartsSample(
          timestamp: parseFloat(cols[0]),
          cpuPercent: parseFloat(cols[1]),
          memUsageMB: parseFloat(cols[2]),
          netRxMB: parseFloat(cols[5]),
          netTxMB: parseFloat(cols[6]),
          downloadRate: parseFloat(cols[3]),
          uploadRate: parseFloat(cols[4]),
        )
      )
    except ValueError:
      discard
  return data

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

when isMainModule:
  let env = getGitHubEnv()
  let outDir = env.sharedVolumePath
  let csvFiles = findCsvFiles(outDir, "docker_stats").sorted

  if csvFiles.len == 0:
    raiseAssert "No docker_stats*.csv files found in " & outDir

  var groups: Table[string, seq[TestRun]]
  for file in csvFiles:
    let data = readCsv(file)
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
  writeGitHubOutputs(output, env, toJobSummary = true, toComment = false)
